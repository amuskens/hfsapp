import Foundation

enum HFSError: LocalizedError, Equatable {
    case notHFS
    case unsupported(String)
    case corrupt(String)
    case notFound(String)
    case alreadyExists(String)
    case directoryNotEmpty(String)
    case invalidName(String)
    case volumeFull
    case catalogFull
    case readOnly
    case invalidMove(String)
    case closed
    case modifiedElsewhere
    case inUse
    case saveIncomplete

    var errorDescription: String? {
        switch self {
        case .notHFS:
            return "The image does not contain an Apple HFS volume."
        case .unsupported(let what):
            return "\(what) is not supported yet."
        case .corrupt(let detail):
            return "The volume appears to be damaged (\(detail))."
        case .notFound(let name):
            // The engine names items by catalog ID ("Item 23"), which means nothing to a user.
            if let last = name.split(separator: " ").last, last.allSatisfy(\.isNumber) {
                return "It is no longer on the disk; it may have been moved or deleted."
            }
            return "\(name) could not be found on the volume."
        case .alreadyExists(let name):
            return "An item named \(name) already exists in this folder."
        case .directoryNotEmpty(let name):
            return "The folder \(name) is not empty."
        case .invalidName(let name):
            return "\(name) is not a valid classic Mac file name."
        case .volumeFull:
            return "There is not enough free space on the volume."
        case .catalogFull:
            return "The volume's catalog is full; no more items can be added."
        case .readOnly:
            return "The volume is read-only."
        case .invalidMove(let detail):
            return detail
        case .closed:
            return "The image was closed."
        case .modifiedElsewhere:
            return "The image was changed by another program while it was open here. To avoid overwriting those changes, nothing was saved; reopen the image to continue."
        case .inUse:
            return "Another program is using the image."
        case .saveIncomplete:
            return "Saving was interrupted while the disk's directory was being rewritten, so the disk may be damaged. Eject the image and check it with Disk First Aid (or fsck_hfs) before using it again."
        }
    }
}

/// Bounds-checked big-endian access. Every offset into on-disk structures comes from the
/// (untrusted) image, so out-of-range reads throw instead of trapping.
extension Array where Element == UInt8 {
    func u8(_ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < count else { throw HFSError.corrupt("read past end of structure") }
        return self[offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw HFSError.corrupt("read past end of structure") }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw HFSError.corrupt("read past end of structure") }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func bytes(_ offset: Int, _ length: Int) throws -> [UInt8] {
        guard offset >= 0, length >= 0, offset + length <= count else { throw HFSError.corrupt("read past end of structure") }
        return Array(self[offset..<(offset + length)])
    }

    /// Writes are only ever made to buffers this code sized itself, so they trap on misuse.
    mutating func put16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value >> 8)
        self[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    mutating func put32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value >> 24)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    mutating func put(_ bytes: [UInt8], at offset: Int) {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
