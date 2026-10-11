import Foundation

/// Runs a shell script as root behind macOS's own authorization dialog, so Bubble never
/// sees or types a password and Macs with Touch ID can approve with a fingerprint.
///
/// The script goes to AppleScript's `do shell script … with administrator privileges`
/// through `osascript`'s argv, so it is never spliced into AppleScript source.
enum Admin {
    enum Failure: Error, Equatable {
        /// The user dismissed the dialog.
        case cancelled
        /// The script ran but exited non-zero (or osascript failed); carries its stderr.
        case failed(String)
    }

    /// - Parameters:
    ///   - script: a `/bin/sh` script, run as root. Quote every path with `Admin.quote`.
    ///   - prompt: shown in the dialog under "Bubble wants to make changes", e.g.
    ///     "Bubble needs to flush the DNS cache."
    /// - Returns: the script's stdout.
    static func run(_ script: String, prompt: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = [
                "-e", "on run argv",
                "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run",
                "--", script, prompt,
            ]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let stderr = String(decoding: errData, as: UTF8.self)
            guard p.terminationStatus == 0 else {
                // AppleScript error -128 is "User canceled."
                if stderr.contains("-128") { throw Failure.cancelled }
                throw Failure.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: outData, as: UTF8.self)
        }.value
    }

    /// Single-quotes `s` for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
