import Foundation
import Darwin

private struct LockFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private struct ApplicationInstanceLockTests {
    private static func outcome(_ acquisition: ApplicationInstanceLock.Acquisition) -> String {
        switch acquisition {
        case .acquired: return "acquired"
        case .alreadyRunning: return "alreadyRunning"
        case .failed(let error): return "failed: \(error)"
        }
    }

    static func main() {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--probe" {
            let lock = ApplicationInstanceLock(settingsURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            let actual = outcome(lock.acquire())
            print("child lock: \(actual)"); fflush(stdout)
            // Intentionally exit without release/deinit: verify kernel cleanup.
            exit(actual == CommandLine.arguments[3] ? 0 : 1)
        }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            guard condition() else { throw LockFailure(description: description) }
            count += 1
        }
        func childProbe(settingsURL: URL, expected: String) throws {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--probe", settingsURL.path, expected]
            try child.run()
            let deadline = Date().addingTimeInterval(4)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning {
                child.terminate() // Only the Process created by this test.
                throw LockFailure(description: "Own lock-probe child exceeded four seconds")
            }
            try check(child.terminationStatus == 0, "cross-process lock result must be \(expected)")
        }
        do {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/tests/application-instance-lock/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settingsURL = directory.appendingPathComponent("settings.json")
            let lockURL = settingsURL.appendingPathExtension("lock")
            let settings = Data("isolated settings sentinel\n".utf8)
            try settings.write(to: settingsURL)
            try Data("stale lock file\n".utf8).write(to: lockURL)
            let first = ApplicationInstanceLock(settingsURL: settingsURL)
            let second = ApplicationInstanceLock(settingsURL: settingsURL)
            try check(outcome(first.acquire()) == "acquired", "an unlocked stale file must not prevent acquisition")
            try check(outcome(first.acquire()) == "acquired", "re-acquiring through the owner must be idempotent")
            try check(outcome(second.acquire()) == "alreadyRunning", "a separate lock object must contend with the owner")
            try childProbe(settingsURL: settingsURL, expected: "alreadyRunning")
            first.release(); first.release()
            try check(outcome(second.acquire()) == "acquired", "explicit release must allow the waiting contender to acquire")
            second.release()
            try childProbe(settingsURL: settingsURL, expected: "acquired")
            try check(outcome(first.acquire()) == "acquired", "kernel must release a child lock after exit without Swift cleanup")
            first.release()
            var scoped: ApplicationInstanceLock? = ApplicationInstanceLock(settingsURL: settingsURL)
            try check(outcome(scoped!.acquire()) == "acquired", "scoped owner must acquire")
            scoped = nil
            try check(outcome(second.acquire()) == "acquired", "owner deinit must release the lock")
            second.release()
            try check(FileManager.default.fileExists(atPath: lockURL.path), "release must leave the stable lock file in place")
            let unchanged = try Data(contentsOf: settingsURL)
            try check(unchanged == settings, "all lock operations must leave settings bytes untouched")
            print("PASS: \(count) ApplicationInstanceLock checks; contention, cross-process exit, stale file, release/reacquire, deinit, unchanged settings")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
