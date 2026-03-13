import Foundation
@testable import SwiftModel

/// File-based debug logger that writes to /tmp for AI agent access
enum FileDebugLogger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentLogFile: String?
    
    /// Start logging to a new file in /tmp
    /// - Parameter testName: Name of the test (used for filename)
    /// - Returns: Path to the log file
    static func startLogging(testName: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "/tmp/swiftmodel_\(testName)_\(timestamp).log"
        
        // Create or clear the file
        try? "".write(toFile: filename, atomically: true, encoding: .utf8)
        
        currentLogFile = filename
        return filename
    }
    
    /// Stop logging and return the log file path
    @discardableResult
    static func stopLogging() -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        let file = currentLogFile
        currentLogFile = nil
        return file
    }
    
    /// Public interface to append a message to the current log file
    static func log(_ message: String) {
        append(message)
    }

    /// Append a message to the current log file
    private static func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let file = currentLogFile else { return }
        
        let line = "\(message)\n"
        
        if let handle = FileHandle(forWritingAtPath: file) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            // File doesn't exist, create it
            try? line.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }
    
    /// Get the current log file path
    static var logFilePath: String? {
        lock.lock()
        defer { lock.unlock() }
        return currentLogFile
    }
}
