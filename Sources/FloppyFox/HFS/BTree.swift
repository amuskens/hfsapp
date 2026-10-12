import Foundation

/// HFS B-tree reading and (re)building. HFS stores the catalog and the extents-overflow file
/// as B*-trees of 512-byte nodes: a header node (node 0) holding the tree header and a node
/// allocation bitmap, optional map nodes continuing that bitmap, index nodes, and doubly
/// linked leaf nodes holding the actual records in key order.
///
/// Rather than splitting and merging nodes in place, the volume keeps every leaf record in a
/// sorted array and writes a freshly packed tree on each flush (`build`). Whole-tree rebuilds
/// can't leave half-split nodes or dangling index keys, and for HFS-sized catalogs (a few MB
/// at most) they cost milliseconds.
enum BTree {
    static let nodeSize = 512
    static let descriptorSize = 14
    static let headerRecordSize = 106
    static let headerNodeMapBytes = 256
    static let mapNodeMapBytes = nodeSize - descriptorSize - 4 // one record, two offsets

    enum NodeKind: UInt8 {
        case index = 0x00
        case header = 0x01
        case map = 0x02
        case leaf = 0xFF
    }

    /// The fields of the header record (BTHdrRec) this code needs, plus the raw record so
    /// reserved bytes survive a rebuild.
    struct Header {
        var raw: [UInt8]

        init(raw: [UInt8]) throws {
            guard raw.count >= headerRecordSize else { throw HFSError.corrupt("short B-tree header") }
            self.raw = Array(raw.prefix(headerRecordSize))
        }

        var depth: UInt16 { get { (try? raw.u16(0)) ?? 0 } set { raw.put16(newValue, at: 0) } }
        var root: UInt32 { get { (try? raw.u32(2)) ?? 0 } set { raw.put32(newValue, at: 2) } }
        var leafRecords: UInt32 { get { (try? raw.u32(6)) ?? 0 } set { raw.put32(newValue, at: 6) } }
        var firstLeaf: UInt32 { get { (try? raw.u32(10)) ?? 0 } set { raw.put32(newValue, at: 10) } }
        var lastLeaf: UInt32 { get { (try? raw.u32(14)) ?? 0 } set { raw.put32(newValue, at: 14) } }
        var nodeSize: UInt16 { (try? raw.u16(18)) ?? 0 }
        var maxKeyLength: UInt16 { (try? raw.u16(20)) ?? 0 }
        var totalNodes: UInt32 { get { (try? raw.u32(22)) ?? 0 } set { raw.put32(newValue, at: 22) } }
        var freeNodes: UInt32 { get { (try? raw.u32(26)) ?? 0 } set { raw.put32(newValue, at: 26) } }
    }

    /// The records of a node, as raw byte slices (key followed by data).
    static func records(of node: [UInt8]) throws -> [[UInt8]] {
        guard node.count == nodeSize else { throw HFSError.corrupt("bad B-tree node size") }
        let count = Int(try node.u16(10))
        guard count <= (nodeSize - descriptorSize) / 2 else { throw HFSError.corrupt("too many records in node") }
        var offsets: [Int] = []
        for index in 0...count {
            offsets.append(Int(try node.u16(nodeSize - 2 * (index + 1))))
        }
        var result: [[UInt8]] = []
        for index in 0..<count {
            let start = offsets[index], end = offsets[index + 1]
            guard start >= descriptorSize, end >= start, end <= nodeSize - 2 * (count + 1) else {
                throw HFSError.corrupt("bad record offsets in B-tree node")
            }
            result.append(Array(node[start..<end]))
        }
        return result
    }

    /// Walks the leaf chain from the header's first leaf, returning every leaf record in order.
    /// `readNode` maps a node number to its 512 bytes.
    static func readLeafRecords(readNode: (UInt32) throws -> [UInt8]) throws -> (header: Header, records: [[UInt8]]) {
        let headerNode = try readNode(0)
        guard try headerNode.u8(8) == NodeKind.header.rawValue else { throw HFSError.corrupt("missing B-tree header node") }
        let header = try Header(raw: try records(of: headerNode).first ?? [])
        guard header.nodeSize == UInt16(nodeSize) else { throw HFSError.unsupported("B-tree node size \(header.nodeSize)") }

        var result: [[UInt8]] = []
        var nodeNumber = header.firstLeaf
        var visited = Set<UInt32>()
        while nodeNumber != 0 {
            guard nodeNumber < header.totalNodes, visited.insert(nodeNumber).inserted else {
                throw HFSError.corrupt("B-tree leaf chain is broken")
            }
            let node = try readNode(nodeNumber)
            guard try node.u8(8) == NodeKind.leaf.rawValue else { throw HFSError.corrupt("B-tree leaf chain reaches a non-leaf node") }
            result += try records(of: node)
            nodeNumber = try node.u32(0)
        }
        guard result.count == Int(header.leafRecords) else {
            throw HFSError.corrupt("B-tree has \(result.count) leaf records, header says \(header.leafRecords)")
        }
        return (header, result)
    }

    /// A leaf record ready for packing: its encoded leaf key + data, and the key in the form
    /// index nodes store.
    struct BuildRecord {
        var leafBytes: [UInt8]
        var indexKey: [UInt8]
    }

    /// Packs `records` (already in key order) into a complete tree of exactly `nodeCount`
    /// nodes. Throws `catalogFull` when they don't fit; the caller grows the file and retries.
    static func build(records: [BuildRecord], nodeCount: Int, template: Header) throws -> [[UInt8]] {
        let mapNodeCount = nodeCount > headerNodeMapBytes * 8
            ? (nodeCount - headerNodeMapBytes * 8 + mapNodeMapBytes * 8 - 1) / (mapNodeMapBytes * 8)
            : 0
        var nodes: [[UInt8]] = []
        var nextNumber = UInt32(1 + mapNodeCount)

        func packed(_ items: [[UInt8]]) throws -> [[[UInt8]]] {
            var groups: [[[UInt8]]] = []
            var current: [[UInt8]] = []
            var used = descriptorSize + 2 // the trailing free-space offset
            for item in items {
                let cost = item.count + 2
                guard descriptorSize + 2 + cost <= nodeSize else { throw HFSError.corrupt("B-tree record too large") }
                if used + cost > nodeSize {
                    groups.append(current)
                    current = []
                    used = descriptorSize + 2
                }
                current.append(item)
                used += cost
            }
            if !current.isEmpty { groups.append(current) }
            return groups
        }

        func makeNode(kind: NodeKind, height: UInt8, records: [[UInt8]]) -> [UInt8] {
            var node = [UInt8](repeating: 0, count: nodeSize)
            node[8] = kind.rawValue
            node[9] = height
            node.put16(UInt16(records.count), at: 10)
            var offset = descriptorSize
            for (index, record) in records.enumerated() {
                node.put16(UInt16(offset), at: nodeSize - 2 * (index + 1))
                node.put(record, at: offset)
                offset += record.count
            }
            node.put16(UInt16(offset), at: nodeSize - 2 * (records.count + 1))
            return node
        }

        var header = template
        header.leafRecords = UInt32(records.count)

        if records.isEmpty {
            header.depth = 0
            header.root = 0
            header.firstLeaf = 0
            header.lastLeaf = 0
        } else {
            // Leaves.
            let leafGroups = try packed(records.map(\.leafBytes))
            var recordIndex = 0
            var height: UInt8 = 1
            var level: [(number: UInt32, node: [UInt8], firstKey: [UInt8])] = []
            for group in leafGroups {
                level.append((nextNumber, makeNode(kind: .leaf, height: height, records: group), records[recordIndex].indexKey))
                recordIndex += group.count
                nextNumber += 1
            }
            header.firstLeaf = level.first!.number
            header.lastLeaf = level.last!.number
            var allLevels: [[(number: UInt32, node: [UInt8], firstKey: [UInt8])]] = [level]

            // Index levels, until a single root remains.
            while level.count > 1 {
                height += 1
                let entries = level.map { child -> [UInt8] in
                    var entry = child.firstKey + [0, 0, 0, 0]
                    entry.put32(child.number, at: child.firstKey.count)
                    return entry
                }
                let groups = try packed(entries)
                var next: [(number: UInt32, node: [UInt8], firstKey: [UInt8])] = []
                var childIndex = 0
                for group in groups {
                    next.append((nextNumber, makeNode(kind: .index, height: height, records: group), level[childIndex].firstKey))
                    childIndex += group.count
                    nextNumber += 1
                }
                level = next
                allLevels.append(level)
            }
            header.depth = UInt16(height)
            header.root = level[0].number

            // Sibling links within every level.
            for levelIndex in allLevels.indices {
                let row = allLevels[levelIndex]
                for i in row.indices {
                    var node = row[i].node
                    node.put32(i + 1 < row.count ? row[i + 1].number : 0, at: 0)
                    node.put32(i > 0 ? row[i - 1].number : 0, at: 4)
                    allLevels[levelIndex][i].node = node
                }
            }
            nodes = allLevels.flatMap { $0.map(\.node) }
        }

        let usedCount = Int(nextNumber)
        guard usedCount <= nodeCount else { throw HFSError.catalogFull }
        header.totalNodes = UInt32(nodeCount)
        header.freeNodes = UInt32(nodeCount - usedCount)

        // Node allocation bitmap: nodes 0..<usedCount are in use (header, maps, tree nodes).
        var bitmap = [UInt8](repeating: 0, count: headerNodeMapBytes + mapNodeCount * mapNodeMapBytes)
        for node in 0..<usedCount { bitmap[node / 8] |= 0x80 >> UInt8(node % 8) }

        var headerNode = makeNode(kind: .header, height: 0, records: [
            header.raw,
            [UInt8](repeating: 0, count: 128),
            Array(bitmap[0..<headerNodeMapBytes]),
        ])
        headerNode.put32(mapNodeCount > 0 ? 1 : 0, at: 0)

        var result = [headerNode]
        for mapIndex in 0..<mapNodeCount {
            let start = headerNodeMapBytes + mapIndex * mapNodeMapBytes
            var mapNode = makeNode(kind: .map, height: 0, records: [Array(bitmap[start..<(start + mapNodeMapBytes)])])
            mapNode.put32(mapIndex + 1 < mapNodeCount ? UInt32(mapIndex + 2) : 0, at: 0)
            result.append(mapNode)
        }
        result += nodes
        result += Array(repeating: [UInt8](repeating: 0, count: nodeSize), count: nodeCount - usedCount)
        return result
    }
}
