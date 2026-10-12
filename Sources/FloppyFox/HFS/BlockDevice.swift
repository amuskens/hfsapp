import Foundation

/// A byte-addressed window onto an image file: the whole file for a bare floppy image, or one
/// partition of a partitioned hard-disk image. All I/O goes through `pread`/`pwrite` on a file
/// descriptor opened once, which works inside the App Sandbox for any user-selected file.
final class BlockDevice {
    let url: URL
    let offset: UInt64
    let length: UInt64
    let isWritable: Bool
    private let fd: Int32

    init(url: URL, offset: UInt64 = 0, length: UInt64? = nil, writable: Bool) throws {
        let fd = open(url.path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fileSize = UInt64(info.st_size)
        guard offset <= fileSize else {
            close(fd)
            throw HFSError.corrupt("partition starts past the end of the image")
        }
        self.url = url
        self.fd = fd
        self.offset = offset
        self.length = min(length ?? (fileSize - offset), fileSize - offset)
        self.isWritable = writable
    }

    deinit {
        close(fd)
    }

    func read(at position: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, position <= length, UInt64(count) <= length - position else {
            throw HFSError.corrupt("read beyond the end of the volume")
        }
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + done, count - done, off_t(offset + position) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { throw HFSError.corrupt("unexpected end of image file") }
            done += n
        }
        return buffer
    }

    func write(_ bytes: [UInt8], at position: UInt64) throws {
        guard isWritable else { throw HFSError.readOnly }
        guard position <= length, UInt64(bytes.count) <= length - position else {
            throw HFSError.corrupt("write beyond the end of the volume")
        }
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                pwrite(fd, raw.baseAddress! + done, bytes.count - done, off_t(offset + position) + off_t(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            done += n
        }
    }

    func synchronize() throws {
        guard isWritable else { return }
        if fsync(fd) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
