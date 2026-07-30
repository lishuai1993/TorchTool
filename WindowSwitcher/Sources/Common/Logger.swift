import Foundation

/// Simple file logger for debugging. Writes timestamped messages to log.txt
/// in the project directory.
final class Logger {
    static let shared = Logger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.windowswitcher.logger", qos: .utility)
    private let dateFormatter: DateFormatter

    private init() {
        // Write log to the project directory
        let projectDir = URL(fileURLWithPath: "/Users/lishuai/lishuai/personal_projects/TorchTool/WindowSwitcher")
        fileURL = projectDir.appendingPathComponent("log.txt")
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        // Truncate old log on startup
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)

        log("══════════════════════════════════════")
        log("WindowSwitcher logger initialized")
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("PID: \(ProcessInfo.processInfo.processIdentifier)")
        log("══════════════════════════════════════")
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = entry.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: self.fileURL, options: .atomic)
                }
            }
        }

        // Also print to stdout for terminal visibility
        print(message)
    }

    /// Synchronous flush — waits for pending writes to complete.
    func flush() {
        queue.sync {}
    }
}

/// Convenience global function
func logDebug(_ message: String, file: String = #file, line: Int = #line) {
    Logger.shared.log(message, file: file, line: line)
}
