import Foundation

public protocol ProviderFetcher: Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    func fetchUsage() async throws -> ProviderUsage
}

public protocol CredentialAcceptingProvider: ProviderFetcher {
    var supportedAuthMethods: [AuthMethod] { get }
    func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage
}

public enum AuthMethod: String {
    case apiKey
}

public struct AccountCredential {
    public var authMethod: AuthMethod
    public var credential: String
    public var metadata: [String: String]
}

public struct ProviderError: Error {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct SourceInfo {
    public init(mode: String, type: String) {}
}

public struct RawQuotaWindow {
    public var usedPercent: Double?
    public var remainingPercent: Double?
    public var resetAt: String?
    public var entitlement: Int?
    public var remaining: Int?
    public init() {}
}

public struct AnyCodable {
    public init(_ value: Any) {}
}

public struct ProviderUsage {
    public var source: SourceInfo?
    public var accountPlan: String?
    public var usageAccountId: String?
    public var primary: RawQuotaWindow?
    public var secondary: RawQuotaWindow?
    public var extra: [String: AnyCodable]
    public init(provider: String, label: String) {
        extra = [:]
    }
}

public enum ProviderAPIRegion: String {
    public static let metadataKey = "apiRegion"
    case auto
    case china
    case international

    public init(metadataValue: String?) {
        self = .auto
    }

    public var allowsCrossRegionFallback: Bool { self == .auto }

    public func orderedEndpoints(_ endpoints: [String], chinaContains: [String], internationalContains: [String]) -> [String] {
        endpoints
    }
}

enum SharedFormatters {
    static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

enum KimiProvider {
    static func num(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : Double(trimmed)
        default:
            return nil
        }
    }

    static func firstString(_ dict: [String: Any]?, _ keys: [String]) -> String? {
        guard let dict else { return nil }
        for key in keys {
            switch dict[key] {
            case let s as String:
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case let n as NSNumber:
                return n.stringValue
            default:
                continue
            }
        }
        return nil
    }

    static func stableFingerprint(_ string: String) -> String { string }
}
