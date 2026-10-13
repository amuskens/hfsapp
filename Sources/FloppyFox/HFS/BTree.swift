import Foundation

/// B-tree reading and (re)building for HFS and HFS Plus. Both store their catalog and
/// extents-overflow files as B*-trees: a header node (node 0) holding the tree header and a
/// node-allocation bitmap, optional map nodes continuing that bitmap, index nodes, and doubly
/// linked leaf nodes holding the records in key order. HFS nodes are always 512 bytes; HFS
/// Plus trees choose their node size (typically 4 KB for the catalog).
///
/// Rather than splitting and merging nodes in place, the volumes keep every leaf record in a
/// sorted array and write a freshly packed tree on each flush (`build`). Whole-tree rebuilds
/// can't leave half-split nodes or dangling index keys; the volumes write the new tree to
/// free space and switch to it with a single volume-header write (see their `flush`).
enum BTree {
    static let descriptorSize = 14
    static let headerRecordSize = 106
    static let userDataRecordSize = 128

    enum NodeKind: UInt8 {
        case index = 0x00
        case header = 0x01
        case map = 0x02
        case leaf = 0xFF
    }

    /// The header node's map record fills the rest of the node after the header record, the
    /// 128-byte user data record, and four record offsets.
    static func headerMapBytes(nodeSize: Int) -> Int {
        nodeSize - descriptorSize - headerRecordSize - userDataRecordSize - 8
    }

    /// A map node holds one record (and two offsets).
    static func mapNodeBytes(nodeSize: Int) -> Int {
        nodeSize - descriptorSize - 4
    }

    static func mapNodeCount(totalNodes: Int, nodeSize: Int) -> Int {
        let inHeader = headerMapBytes(nodeSize: nodeSize) * 8
        guard totalNodes > inHeader else { return 0 }
        let perMapNode = mapNodeBytes(nodeSize: nodeSize) * 8
        return (totalNodes - inHeader + perMapNode - 1) / perMapNode
    }

    /// The fields of the header record (BTHdrRec / BTHeaderRec) this code needs, plus the raw
    /// record so everything else (clump size, key compare type, attributes) survives.
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
    static func records(of node: [UInt8], nodeSize: Int = 512) throws -> [[UInt8]] {
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
    /// `readNode` maps a node number to its bytes.
    static func readLeafRecords(nodeSize: Int = 512, readNode: (UInt32) throws -> [UInt8]) throws -> (header: Header, records: [[UInt8]]) {
        let headerNode = try readNode(0)
        guard try headerNode.u8(8) == NodeKind.header.rawValue else { throw HFSError.corrupt("missing B-tree header node") }
        let header = try Header(raw: try records(of: headerNode, nodeSize: nodeSize).first ?? [])
        guard Int(header.nodeSize) == nodeSize else { throw HFSError.unsupported("B-tree node size \(header.nodeSize)") }

        var result: [[UInt8]] = []
        var nodeNumber = header.firstLeaf
        var visited = Set<UInt32>()
        while nodeNumber != 0 {
            guard nodeNumber < header.totalNodes, visited.insert(nodeNumber).inserted else {
                throw HFSError.corrupt("B-tree leaf chain is broken")
            }
            let node = try readNode(nodeNumber)
            guard try node.u8(8) == NodeKind.leaf.rawValue else { throw HFSError.corrupt("B-tree leaf chain reaches a non-leaf node") }
            result += try records(of: node, nodeSize: nodeSize)
            nodeNumber = try node.u32(0)
        }
        guard result.count == Int(header.leafRecords) else {
            throw HFSError.corrupt("B-tree has \(result.count) leaf records, header says \(header.leafRecords)")
        }
        return (header, result)
    }

    /// A leaf record ready for packing: its encoded key + data, and the key in the form index
    /// nodes store.
    struct BuildRecord {
        var leafBytes: [UInt8]
        var indexKey: [UInt8]
    }

    /// Groups items into nodes in order, as many per node as fit.
    private static func pack(_ items: [[UInt8]], nodeSize: Int) throws -> [[[UInt8]]] {
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

    /// Leaf and index nodes the records need (excluding the header and map nodes).
    static func treeNodeCount(records: [BuildRecord], nodeSize: Int) throws -> Int {
        guard !records.isEmpty else { return 0 }
        let leafGroups = try pack(records.map(\.leafBytes), nodeSize: nodeSize)
        var keys: [[UInt8]] = []
        var index = 0
        for group in leafGroups {
            keys.append(records[index].indexKey)
            index += group.count
        }
        var total = leafGroups.count
        while keys.count > 1 {
            let groups = try pack(keys.map { $0 + [0, 0, 0, 0] }, nodeSize: nodeSize)
            var next: [[UInt8]] = []
            var position = 0
            for group in groups {
                next.append(keys[position])
                position += group.count
            }
            keys = next
            total += groups.count
        }
        return total
    }

    /// The smallest node count a tree file must have to hold `records`: header, map nodes
    /// (which depend on the total), leaves and index nodes.
    static func minimumNodeCount(records: [BuildRecord], nodeSize: Int) throws -> Int {
        let tree = try treeNodeCount(records: records, nodeSize: nodeSize)
        var total = tree + 1
        while 1 + mapNodeCount(totalNodes: total, nodeSize: nodeSize) + tree > total {
            total = 1 + mapNodeCount(totalNodes: total, nodeSize: nodeSize) + tree
        }
        return total
    }

    /// Packs `records` (already in key order) into a complete tree of exactly `nodeCount`
    /// nodes. Throws `catalogFull` when they don't fit.
    static func build(records: [BuildRecord], nodeCount: Int, template: Header, nodeSize: Int = 512) throws -> [[UInt8]] {
        let mapNodes = mapNodeCount(totalNodes: nodeCount, nodeSize: nodeSize)
        var nextNumber = UInt32(1 + mapNodes)

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
        var treeNodes: [[UInt8]] = []

        if records.isEmpty {
            header.depth = 0
            header.root = 0
            header.firstLeaf = 0
            header.lastLeaf = 0
        } else {
            typealias Built = (number: UInt32, node: [UInt8], firstKey: [UInt8])
            var recordIndex = 0
            var height: UInt8 = 1
            var level: [Built] = []
            for group in try pack(records.map(\.leafBytes), nodeSize: nodeSize) {
                level.append((nextNumber, makeNode(kind: .leaf, height: height, records: group), records[recordIndex].indexKey))
                recordIndex += group.count
                nextNumber += 1
            }
            header.firstLeaf = level.first!.number
            header.lastLeaf = level.last!.number
            var allLevels: [[Built]] = [level]

            while level.count > 1 {
                height += 1
                let entries = level.map { child -> [UInt8] in
                    var entry = child.firstKey + [0, 0, 0, 0]
                    entry.put32(child.number, at: child.firstKey.count)
                    return entry
                }
                var next: [Built] = []
                var childIndex = 0
                for group in try pack(entries, nodeSize: nodeSize) {
                    next.append((nextNumber, makeNode(kind: .index, height: height, records: group), level[childIndex].firstKey))
                    childIndex += group.count
                    nextNumber += 1
                }
                level = next
                allLevels.append(level)
            }
            header.depth = UInt16(height)
            header.root = level[0].number

            for levelIndex in allLevels.indices {
                let row = allLevels[levelIndex]
                for i in row.indices {
                    var node = row[i].node
                    node.put32(i + 1 < row.count ? row[i + 1].number : 0, at: 0)
                    node.put32(i > 0 ? row[i - 1].number : 0, at: 4)
                    allLevels[levelIndex][i].node = node
                }
            }
            treeNodes = allLevels.flatMap { $0.map(\.node) }
        }

        let usedCount = Int(nextNumber)
        guard usedCount <= nodeCount else { throw HFSError.catalogFull }
        header.totalNodes = UInt32(nodeCount)
        header.freeNodes = UInt32(nodeCount - usedCount)

        let headerMap = headerMapBytes(nodeSize: nodeSize)
        let mapBytes = mapNodeBytes(nodeSize: nodeSize)
        var bitmap = [UInt8](repeating: 0, count: headerMap + mapNodes * mapBytes)
        for node in 0..<usedCount { bitmap[node / 8] |= 0x80 >> UInt8(node % 8) }

        var headerNode = makeNode(kind: .header, height: 0, records: [
            header.raw,
            [UInt8](repeating: 0, count: userDataRecordSize),
            Array(bitmap[0..<headerMap]),
        ])
        headerNode.put32(mapNodes > 0 ? 1 : 0, at: 0)

        var result = [headerNode]
        for mapIndex in 0..<mapNodes {
            let start = headerMap + mapIndex * mapBytes
            var mapNode = makeNode(kind: .map, height: 0, records: [Array(bitmap[start..<(start + mapBytes)])])
            mapNode.put32(mapIndex + 1 < mapNodes ? UInt32(mapIndex + 2) : 0, at: 0)
            result.append(mapNode)
        }
        result += treeNodes
        result += Array(repeating: [UInt8](repeating: 0, count: nodeSize), count: nodeCount - usedCount)
        return result
    }
}
