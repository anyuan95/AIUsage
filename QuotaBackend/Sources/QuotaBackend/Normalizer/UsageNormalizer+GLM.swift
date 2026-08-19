import Foundation

extension UsageNormalizer {

    // MARK: - GLM Coding Plan
    // 把 monitor `/api/monitor/usage/quota/limit` 的 5 小时滚动 + 周窗口规整成统一卡片，
    // 排版与 Codex / Kimi / MiniMax 对齐：primary → 5h Window，secondary → Weekly Window。

    static func normalizeGLM(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        var windows: [WindowInfo] = []
        if let w = usage.primary {
            let label = extraString(usage, "primaryLabel").flatMap { $0.isEmpty ? nil : $0 } ?? "5h Window"
            windows.append(createPercentWindow(label: label, window: w))
        }
        if let w = usage.secondary {
            let label = extraString(usage, "secondaryLabel").flatMap { $0.isEmpty ? nil : $0 } ?? "Weekly Window"
            windows.append(createPercentWindow(label: label, window: w))
        }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)

        let planName = usage.accountPlan?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Coding Plan"
        let rateReset = usage.primary?.resetAt
        let weeklyReset = usage.secondary?.resetAt

        var metrics: [MetricInfo] = [
            MetricInfo(label: "Plan", value: planName)
        ]
        if let email = usage.accountEmail?.nilIfEmpty {
            metrics.append(MetricInfo(label: "Account", value: email))
        }
        if let reset = formatShortDateTime(rateReset) {
            metrics.append(MetricInfo(label: "5h Reset", value: reset))
        }
        if let reset = formatShortDateTime(weeklyReset) {
            metrics.append(MetricInfo(label: "Weekly Reset", value: reset))
        }
        metrics.append(MetricInfo(label: "Source", value: formatSourceLabel(usage.source)))

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: usage.accountPlan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = rateReset ?? weeklyReset
        base.nextResetLabel = formatShortDateTime(rateReset ?? weeklyReset)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(planName)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Tracked",
            secondary: remainingPercent == nil ? "GLM Coding Plan usage" : "tightest GLM Coding Plan window",
            supporting: usage.accountEmail?.nilIfEmpty ?? "GLM Coding Plan"
        )
        base.metrics = metrics
        base.windows = windows
        base.spotlight = "GLM Coding Plan shares one credit pool across CLI, IDE, and API keys. The 5-hour rolling window recovers after use; the weekly window resets every 7 days. China and International keys are not interchangeable."
        return base
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
