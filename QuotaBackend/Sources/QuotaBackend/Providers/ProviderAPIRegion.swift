import Foundation

/// MiniMax / Kimi / GLM 等海内外分站 API 的区域偏好。
/// 存入 `AccountCredential.metadata["apiRegion"]`；缺省为 `.auto`。
public enum ProviderAPIRegion: String, Codable, CaseIterable, Sendable {
    case auto
    case china
    case international

    public static let metadataKey = "apiRegion"

    public init(metadataValue: String?) {
        let raw = metadataValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case Self.china.rawValue, "cn", "domestic":
            self = .china
        case Self.international.rawValue, "global", "intl", "overseas":
            self = .international
        default:
            self = .auto
        }
    }

    /// 按偏好重排端点：显式区域把对应端点放最前；`.auto` 保持传入顺序。
    public func orderedEndpoints(_ endpoints: [String], chinaContains: [String], internationalContains: [String]) -> [String] {
        guard endpoints.count > 1 else { return endpoints }
        func matches(_ url: String, needles: [String]) -> Bool {
            let lower = url.lowercased()
            return needles.contains { lower.contains($0) }
        }
        switch self {
        case .auto:
            return endpoints
        case .china:
            let preferred = endpoints.filter { matches($0, needles: chinaContains) }
            let rest = endpoints.filter { !matches($0, needles: chinaContains) }
            return preferred + rest
        case .international:
            let preferred = endpoints.filter { matches($0, needles: internationalContains) }
            let rest = endpoints.filter { !matches($0, needles: internationalContains) }
            return preferred + rest
        }
    }

    /// 显式区域时是否允许跨区回退。`.auto` 始终尝试全部。
    public var allowsCrossRegionFallback: Bool {
        switch self {
        case .auto: return true
        case .china, .international: return false
        }
    }
}
