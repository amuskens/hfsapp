import Foundation

/// A byte-addressed window onto an image file: the whole file for a bare floppy image, or one
/// partition of a partitioned hard-disk image. All I/O goes through `pread`/`pwrite` on a file
/// descriptor opened once, which works inside the App Sandbox for any user-selected file.
/// Fails every write after a set number succeed — a stand-in for the power going out, used
/// by tests to check that a flush interrupted at any point leaves a consistent volume.
final class WriteFaultInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?
    private(set) var writesSeen = 0

    /// Allow `count` more writes, then fail all of them (nil: never fail).
    func failAfter(_ count: Int?) {
        lock.lock()
        remaining = count
        writesSeen = 0
        lock.unlock()
    }

    fileprivate func permitWrite() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writesSeen += 1
        guard let left = remaining else { return true }
        if left <= 0 { return false }
        remaining = left - 1
        return true
    }
}

final class BlockDevice {
    let url: URL
    let offset: UInt64
    let length: UInt64
    let isWritable: Bool
    private var fd: Int32
    private let faults: WriteFaultInjector?

    init(url: URL, offset: UInt64 = 0, length: UInt64? = nil, writable: Bool, faults: WriteFaultInjector? = nil) throws {
        self.faults = faults
        let fd = open(url.path, writable ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fileSize = UInt64(info.st_size)
        guard offset <= fileSize else {
            Darwin.close(fd)
            throw HFSError.corrupt("partition starts past the end of the image")
        }
        // An exclusive advisory lock for writers, so two openers (another FloppyFox window, a
        // stale engine instance, any tool that honours flock) never write the image at once.
        if writable, flock(fd, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(fd)
            throw HFSError.inUse
        }
        self.url = url
        self.fd = fd
        self.offset = offset
        self.length = min(length ?? (fileSize - offset), fileSize - offset)
        self.isWritable = writable
    }

    deinit {
        close()
    }

    /// Releases the file (and its lock). Later reads and writes throw.
    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    func read(at position: UInt64, count: Int) throws -> [UInt8] {
        guard fd >= 0 else { throw HFSError.closed }
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
        guard fd >= 0 else { throw HFSError.closed }
        guard isWritable else { throw HFSError.readOnly }
        if let faults, !faults.permitWrite() { throw POSIXError(.EIO) }
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
        guard isWritable, fd >= 0 else { return }
        // Commits are ordered (new trees, then the volume header), so each step must really be
        // on the medium before the next: plain fsync on macOS can leave data in the drive's
        // cache. F_FULLFSYNC isn't supported everywhere (e.g. some network volumes); fall back.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
