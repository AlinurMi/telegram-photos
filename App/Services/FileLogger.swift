import Foundation

/// Appends log lines to `Application Support/Logs/app.log` and mirrors them to `os.Logger`.
///
/// The log is shared from Settings → Advanced, so it must never contain:
/// - the Telegram `api_hash`, the phone number, login codes or the 2FA password
/// - caption text
/// - location coordinates
///
/// Asset tags, unit ids, filenames, sizes and error messages are fine.
import os

/// The app-wide logger.
actor FileLogger {
    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        fileprivate var osLevel: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    static let shared = FileLogger()

    private enum Command: Sendable {
        case line(Date, Level, String, String)
        case flush(CheckedContinuation<Void, Never>)
    }

    private static let currentName = "app.log"
    private static let previousName = "app.1.log"

    private let directory: URL
    private let maxBytes: Int
    private let subsystem: String
    private let fileManager = FileManager.default
    private let formatter = ISO8601DateFormatter()
    private var osLoggers: [String: Logger] = [:]
    private var file: FileHandle?
    private var currentSize = 0

    // Entries go through a stream so lines keep the order in which they were logged.
    private nonisolated let commands: AsyncStream<Command>.Continuation

    /// - Parameters:
    ///   - directory: Where the log files live. Defaults to `Application Support/Logs`.
    ///   - maxBytes: Size at which `app.log` rotates to `app.1.log`.
    ///   - subsystem: The `os.Logger` subsystem. Defaults to the bundle id.
    init(directory: URL? = nil, maxBytes: Int = 5 * 1024 * 1024, subsystem: String? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.temporaryDirectory
        self.directory =
            directory
            ?? (support ?? fallback).appendingPathComponent("Logs", isDirectory: true)
        self.maxBytes = maxBytes
        self.subsystem = subsystem ?? Bundle.main.bundleIdentifier ?? "io.github.alinurmi.telegramphotos"

        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        self.commands = continuation
        Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.process(command)
            }
        }
    }

    deinit {
        commands.finish()
    }

    nonisolated func debug(_ message: String, category: String = "app") {
        enqueue(.debug, category, message)
    }

    nonisolated func info(_ message: String, category: String = "app") {
        enqueue(.info, category, message)
    }

    nonisolated func warning(_ message: String, category: String = "app") {
        enqueue(.warning, category, message)
    }

    nonisolated func error(_ message: String, category: String = "app") {
        enqueue(.error, category, message)
    }

    /// Waits until every line logged so far has been written to disk.
    func flush() async {
        await withCheckedContinuation { continuation in
            commands.yield(.flush(continuation))
        }
    }

    /// The log files that exist, newest first, ready for a ShareLink.
    func exportURLs() -> [URL] {
        [Self.currentName, Self.previousName]
            .map { directory.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private nonisolated func enqueue(_ level: Level, _ category: String, _ message: String) {
        commands.yield(.line(Date(), level, category, message))
    }

    private func process(_ command: Command) {
        switch command {
        case .line(let date, let level, let category, let message):
            append(date: date, level: level, category: category, message: message)
        case .flush(let continuation):
            continuation.resume()
        }
    }

    private func append(date: Date, level: Level, category: String, message: String) {
        osLogger(for: category).log(level: level.osLevel, "\(message, privacy: .public)")

        let line = "\(formatter.string(from: date)) [\(level.rawValue)] [\(category)] \(message)\n"
        let data = Data(line.utf8)
        do {
            if currentSize + data.count > maxBytes, currentSize > 0 {
                try rotate()
            }
            let handle = try openHandle()
            try handle.write(contentsOf: data)
            currentSize += data.count
        } catch {
            // Logging must never crash the app; the os.Logger copy above still exists.
            osLogger(for: "logger").error("Could not write log file: \(error.localizedDescription, privacy: .public)")
            try? file?.close()
            file = nil
        }
    }

    private func osLogger(for category: String) -> Logger {
        if let existing = osLoggers[category] { return existing }
        let created = Logger(subsystem: subsystem, category: category)
        osLoggers[category] = created
        return created
    }

    private func openHandle() throws -> FileHandle {
        if let file { return file }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.currentName)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        currentSize = Int(try handle.seekToEnd())
        file = handle
        return handle
    }

    private func rotate() throws {
        try file?.close()
        file = nil
        let current = directory.appendingPathComponent(Self.currentName)
        let previous = directory.appendingPathComponent(Self.previousName)
        if fileManager.fileExists(atPath: previous.path) {
            try fileManager.removeItem(at: previous)
        }
        try fileManager.moveItem(at: current, to: previous)
        currentSize = 0
    }
}
let log = FileLogger.shared
