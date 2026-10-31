import Foundation

enum StartupMode: String, CaseIterable, Identifiable {
    case lastUsed
    case questClient
    case directUSB

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastUsed: return "Last used mode"
        case .questClient: return "Quest Client (APK)"
        case .directUSB: return "Direct USB"
        }
    }
}

enum StartupPreferences {
    private static let modeKey = "startupMode"
    private static let lastKey = "lastTransport"

    static var mode: StartupMode {
        get { UserDefaults.standard.string(forKey: modeKey).flatMap(StartupMode.init(rawValue:)) ?? .lastUsed }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static func transport(configured: ConnectionTransport) -> ConnectionTransport {
        switch mode {
        case .questClient: return .questClient
        case .directUSB: return .directMonado
        case .lastUsed:
            return UserDefaults.standard.string(forKey: lastKey).flatMap(ConnectionTransport.init(rawValue:)) ?? configured
        }
    }

    static func record(_ transport: ConnectionTransport) {
        UserDefaults.standard.set(transport.rawValue, forKey: lastKey)
    }
}
