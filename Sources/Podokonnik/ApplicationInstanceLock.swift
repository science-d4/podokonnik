import Foundation
import Darwin

/// A process-held lock. The file can survive a crash; the kernel releases its lock.
final class ApplicationInstanceLock {
    enum Acquisition {
        case acquired
        case alreadyRunning
        case failed(String)
    }

    private let url: URL
    private var descriptor: Int32 = -1

    init(settingsURL: URL) { url = settingsURL.appendingPathExtension("lock") }

    func acquire() -> Acquisition {
        if descriptor >= 0 { return .acquired }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { return .failed(error.localizedDescription) }
        let opened = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { return .failed(String(cString: strerror(errno))) }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(opened)
            return error == EWOULDBLOCK ? .alreadyRunning : .failed(String(cString: strerror(error)))
        }
        descriptor = opened
        return .acquired
    }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
