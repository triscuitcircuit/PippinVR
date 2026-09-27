import Foundation

enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    var color: String {
        switch self {
        case .debug: return "\u{001B}[0;36m"
        case .info: return "\u{001B}[0;32m"
        case .warning: return "\u{001B}[0;33m"
        case .error: return "\u{001B}[0;31m"
        }
    }

    static let reset = "\u{001B}[0m"
    
    var name: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct Logger {
    nonisolated(unsafe) static var minimumLevel: LogLevel = .debug
    
    static func debug(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .debug, file: file, function: function, line: line)
    }

    static func info(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .info, file: file, function: function, line: line)
    }

    static func warning(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .warning, file: file, function: function, line: line)
    }

    static func error(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(message, level: .error, file: file, function: function, line: line)
    }

    private static func log(
        _ message: String,
        level: LogLevel,
        file: String,
        function: String,
        line: Int
    ) {
        guard level >= minimumLevel else { return }
        
        let className = extractClassName(from: file)
        let timestamp = formatTimestamp()

        print("[\(timestamp)] \(level.color)\(level.name)\(LogLevel.reset) [\(className).\(function)] \(message)")
    }
    
    private static func extractClassName(from filePath: String) -> String {
        let filename = URL(fileURLWithPath: filePath).lastPathComponent
        return filename.replacingOccurrences(of: ".swift", with: "")
    }
    
    private static func formatTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

extension Logger {
    static func info(
        _ message: String,
        context: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let contextMessage = "[\(context)] \(message)"
        log(contextMessage, level: .info, file: file, function: function, line: line)
    }
    
    static func debug(
        _ message: String,
        context: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let contextMessage = "[\(context)] \(message)"
        log(contextMessage, level: .debug, file: file, function: function, line: line)
    }
}
