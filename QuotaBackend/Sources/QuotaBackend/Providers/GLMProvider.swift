import Foundation

// MARK: - GLM Coding Plan Provider
// 监控智谱 / Z.AI GLM Coding Plan 的订阅额度：5 小时滚动窗口 + 周窗口。
//
// 请求形状对齐 cc-switch `coding_plan.rs::query_zhipu`（实测）：
//   GET https://open.bigmodel.cn/api/monitor/usage/quota/limit   （国内，base 含 bigmodel.cn）
//   GET https://api.z.ai/api/monitor/usage/quota/limit           （国际，其余情况）
//   Header: Authorization: <Coding Plan API Key>   ← 智谱不加 Bearer 前缀
//           Content-Type: application/json
//           Accept-Language: en-US,en
//
// 响应（个人版与团队版同形；首版只做个人 Key）：
//   { "code": 200, "success": true, "data": {
//        "level": "lite",
//        "limits": [
//          { "type": "TOKENS_LIMIT" | "CREDIT_LIMIT", "unit": 3, "number": 5,
//            "usage": 2000, "currentValue": 71, "remaining": 1929,
//            "percentage": 3, "nextResetTime": 1786073946574 },
//          { "type": "TOKENS_LIMIT" | "CREDIT_LIMIT", "unit": 6, "number": 1 | 7, ... }
//        ]
//     } }
// `percentage` = 已用百分比（cc-switch 主字段）。`usage` = 窗口上限，
// `currentValue` = 已消耗。unit 3 = 5 小时窗，unit 6 = 周窗（不绑 number）。
// TIME_LIMIT 是搜索类额度，主卡片跳过。按量付费 Key 查不到这组 limits。
//
// 区域：cc-switch 按用户已配置的 coding base_url 定点请求、不做跨站回退。
// AIUsage 没有这份 base_url，所以用与 MiniMax 相同的区域选择 + auto 回退。

public struct GLMProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "glm"
    public let displayName = "GLM Coding Plan"
    public let description = "GLM Coding Plan 5-hour and weekly subscription credits"

    static let usageEndpoints = [
        "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
        "https://api.z.ai/api/monitor/usage/quota/limit"
    ]
    static let userAgent = "AIUsage-GLMMonitor/1.0"

    let timeoutSeconds: Double

    public var supportedAuthMethods: [AuthMethod] { [.apiKey] }

    public init(timeoutSeconds: Double = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage() async throws -> ProviderUsage {
        throw ProviderError(
            "not_logged_in",
            "No GLM Coding Plan key found. Paste a Coding Plan API key from open.bigmodel.cn or z.ai."
        )
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard supportedAuthMethods.contains(credential.authMethod) else {
            throw ProviderError(
                "unsupported_auth_method",
                "GLM Coding Plan only accepts API key credentials."
            )
        }
        let key = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderError("missing_token", "GLM Coding Plan API key is empty.")
        }
        let region = ProviderAPIRegion(metadataValue: credential.metadata[ProviderAPIRegion.metadataKey])
        return try await fetchUsage(
            apiKey: key,
            source: SourceInfo(mode: "manual", type: "manual-api-key"),
            region: region
        )
    }

    private func fetchUsage(apiKey: String, source: SourceInfo, region: ProviderAPIRegion) async throws -> ProviderUsage {
        let (root, resolvedRegion) = try await fetchUsageRoot(apiKey: apiKey, region: region)
        let parsed = try GLMCodingPlanQuotaParser.parse(root)

        var usage = ProviderUsage(provider: id, label: displayName)
        usage.source = source
        usage.accountPlan = parsed.planName
        usage.usageAccountId = "glm-\(KimiProvider.stableFingerprint(apiKey))"

        var extra: [String: AnyCodable] = [:]
        if let session = parsed.session {
            usage.primary = session
            extra["primaryLabel"] = AnyCodable("5h Window")
            if let weekly = parsed.weekly {
                usage.secondary = weekly
                extra["secondaryLabel"] = AnyCodable("Weekly Window")
            }
        } else if let weekly = parsed.weekly {
            usage.primary = weekly
            extra["primaryLabel"] = AnyCodable("Weekly Window")
        }

        guard usage.primary != nil else {
            throw ProviderError(
                "empty_usage",
                "GLM Coding Plan response did not include a usable 5-hour or weekly quota window."
            )
        }

        extra[ProviderAPIRegion.metadataKey] = AnyCodable(resolvedRegion.rawValue)
        usage.extra = extra
        return usage
    }

    private func fetchUsageRoot(
        apiKey: String,
        region: ProviderAPIRegion
    ) async throws -> (root: [String: Any], resolved: ProviderAPIRegion) {
        var sawAuthFailure = false
        var lastError: Error?
        let endpoints = region.orderedEndpoints(
            Self.usageEndpoints,
            chinaContains: ["bigmodel.cn"],
            internationalContains: ["z.ai"]
        )
        let candidates = region.allowsCrossRegionFallback ? endpoints : Array(endpoints.prefix(1))
        let authorization = Self.authorizationHeaderValue(from: apiKey)

        for endpoint in candidates {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        sawAuthFailure = true
                        continue
                    }
                    lastError = ProviderError("http_error", "GLM Coding Plan request failed (HTTP \(http.statusCode)).")
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = ProviderError("parse_failed", "GLM Coding Plan returned invalid JSON.")
                    continue
                }

                if GLMCodingPlanQuotaParser.isAuthFailure(json) {
                    sawAuthFailure = true
                    continue
                }

                do {
                    _ = try GLMCodingPlanQuotaParser.parse(json)
                    let resolved: ProviderAPIRegion = endpoint.contains("bigmodel.cn") ? .china : .international
                    return (json, resolved)
                } catch {
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }

        if sawAuthFailure {
            throw ProviderError("invalid_credentials", regionAuthFailureMessage(region))
        }
        throw lastError ?? ProviderError("unknown_error", "GLM Coding Plan request failed.")
    }

    /// 智谱额度接口要求裸 Key。用户若粘贴了 `Bearer …`，去掉前缀再发。
    static func authorizationHeaderValue(from apiKey: String) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "bearer "
        if trimmed.lowercased().hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func regionAuthFailureMessage(_ region: ProviderAPIRegion) -> String {
        switch region {
        case .china:
            return "GLM Coding Plan key was rejected by the China endpoint (open.bigmodel.cn). Check the key, or switch to International."
        case .international:
            return "GLM Coding Plan key was rejected by the International endpoint (api.z.ai). Check the key, or switch to China."
        case .auto:
            return "GLM Coding Plan key is invalid, is pay-as-you-go, or belongs to the other region (China / International)."
        }
    }
}

enum GLMCodingPlanQuotaParser {
    struct Parsed {
        var planName: String
        var session: RawQuotaWindow?
        var weekly: RawQuotaWindow?
    }

    private enum WindowKind {
        case session
        case weekly
    }

    static func isAuthFailure(_ json: [String: Any]) -> Bool {
        let code = Int(KimiProvider.num(json["code"]) ?? 0)
        if code == 401 || code == 403 {
            return true
        }
        guard let success = json["success"] as? Bool, success == false else {
            return false
        }
        let message = (KimiProvider.firstString(json, ["msg", "message"]) ?? "").lowercased()
        return message.contains("unauthorized") || message.contains("invalid api")
    }

    static func parse(_ json: [String: Any]) throws -> Parsed {
        if let success = json["success"] as? Bool, success == false {
            let msg = KimiProvider.firstString(json, ["msg", "message"]) ?? "GLM Coding Plan request failed."
            throw ProviderError("api_error", msg)
        }
        if let code = KimiProvider.num(json["code"]), code != 200, code != 0 {
            let msg = KimiProvider.firstString(json, ["msg", "message"]) ?? "GLM Coding Plan request failed."
            throw ProviderError("api_error", msg)
        }

        let (limits, level) = extractLimits(json["data"])
        let quotaEntries = limits.filter(isQuotaLimitType)
        guard !quotaEntries.isEmpty else {
            throw ProviderError(
                "empty_usage",
                "This key did not return Coding Plan quotas. Use a Coding Plan key from open.bigmodel.cn or z.ai, not a pay-as-you-go key."
            )
        }

        var session: RawQuotaWindow?
        var weekly: RawQuotaWindow?
        var unclassified: [(resetMs: Double?, window: RawQuotaWindow)] = []

        for entry in quotaEntries {
            let window = parseWindow(entry)
            let resetMs = KimiProvider.num(entry["nextResetTime"])
            switch classifyWindow(entry) {
            case .session where session == nil:
                session = window
            case .weekly where weekly == nil:
                weekly = window
            default:
                unclassified.append((resetMs, window))
            }
        }

        unclassified.sort { lhs, rhs in
            switch (lhs.resetMs, rhs.resetMs) {
            case (nil, nil):
                return false
            case (nil, _):
                return true
            case (_, nil):
                return false
            case let (left?, right?):
                return left < right
            }
        }
        for item in unclassified {
            if session == nil {
                session = item.window
            } else if weekly == nil {
                weekly = item.window
            }
        }

        guard session != nil || weekly != nil else {
            throw ProviderError("empty_usage", "GLM Coding Plan response did not include a usable quota window.")
        }

        return Parsed(planName: planDisplayName(level), session: session, weekly: weekly)
    }

    private static func extractLimits(_ data: Any?) -> (limits: [[String: Any]], level: String?) {
        if let object = data as? [String: Any] {
            let level = KimiProvider.firstString(object, ["level", "plan", "tier"])
            let raw = object["limits"] as? [Any] ?? []
            return (raw.compactMap { $0 as? [String: Any] }, level)
        }
        if let list = data as? [Any] {
            return (list.compactMap { $0 as? [String: Any] }, nil)
        }
        return ([], nil)
    }

    private static func isQuotaLimitType(_ entry: [String: Any]) -> Bool {
        let type = entry["type"] as? String ?? ""
        return type.caseInsensitiveCompare("TOKENS_LIMIT") == .orderedSame
            || type.caseInsensitiveCompare("CREDIT_LIMIT") == .orderedSame
    }

    private static func classifyWindow(_ entry: [String: Any]) -> WindowKind? {
        switch Int(KimiProvider.num(entry["unit"]) ?? -1) {
        case 3: return .session
        case 6: return .weekly
        default: return nil
        }
    }

    private static func parseWindow(_ entry: [String: Any]) -> RawQuotaWindow {
        let limit = KimiProvider.num(entry["usage"])
        let used = KimiProvider.num(entry["currentValue"])
        let remaining = KimiProvider.num(entry["remaining"])
        let usedPercentField = KimiProvider.num(entry["percentage"])
        let resetMs = KimiProvider.num(entry["nextResetTime"])

        var window = RawQuotaWindow()
        if let limit { window.entitlement = Int(limit.rounded()) }
        if let remaining { window.remaining = Int(max(0, remaining).rounded()) }

        if let limit, limit > 0, let used {
            let usedPct = used / limit * 100
            window.usedPercent = usedPct
            window.remainingPercent = 100 - usedPct
            if window.remaining == nil {
                window.remaining = Int(max(0, limit - used).rounded())
            }
        } else {
            let usedPct = usedPercentField ?? 0
            window.usedPercent = usedPct
            window.remainingPercent = 100 - usedPct
        }

        if let resetMs, resetMs > 0 {
            window.resetAt = SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: resetMs / 1000))
        }
        return window
    }

    private static func planDisplayName(_ level: String?) -> String {
        switch level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "lite": return "Lite"
        case "pro": return "Pro"
        case "max": return "Max"
        case "standard": return "Standard"
        case let value?:
            return value.isEmpty ? "Coding Plan" : value
        case nil:
            return "Coding Plan"
        }
    }
}
