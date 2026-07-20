import Darwin
import Foundation

public enum ProcessTerminator {
    /// Stops a child process without allowing a stuck data plane to block Direct forever.
    @discardableResult
    public static func stop(_ process: Process, graceSeconds: Double = 2.0) -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < killDeadline { usleep(20_000) }
        if !process.isRunning { process.waitUntilExit() }
        return !process.isRunning
    }
}
