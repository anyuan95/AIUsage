import SwiftUI
import QuotaBackend

extension ProviderAccountEditorView {

    // MARK: - Actions

    func iconName(for action: ProviderAuthLaunchAction) -> String {
        if providerId == "codex", action.id == "codex-login" { return "globe" }
        if providerId == "gemini", action.id == "gemini-login" { return "globe" }
        if providerId == "antigravity", action.id == "antigravity-login" { return "globe" }
        if providerId == "copilot", action.id == "copilot-gh-login" { return "globe" }
        if providerId == "kiro", action.id == "kiro-login" { return "globe" }
        if providerId == "warp", action.id == "warp-open" { return "app.badge" }
        if providerId == "warp", action.id == "warp-check" { return "checkmark.circle" }
        if providerId == "warp", action.id == "warp-site" { return "safari" }
        switch action.kind {
        case .openApp: return "app.badge"
        case .openURL: return "safari"
        case .revealPath: return "folder"
        case .runTerminal: return "terminal"
        }
    }

    func performLaunch(_ action: ProviderAuthLaunchAction) {
        errorMessage = nil
        statusMessage = nil

        if providerId == "codex",
           case .runTerminal(let command) = action.kind,
           command == "codex login" {
            showCodexBrowser = true
            sessionMonitorTask?.cancel()
            codexLogin.start()
            return
        }

        if providerId == "gemini",
           case .runTerminal(let command) = action.kind,
           command == "gemini" {
            sessionMonitorTask?.cancel()
            geminiLogin.start()
            return
        }

        if providerId == "antigravity",
           case .runTerminal(let command) = action.kind,
           command == "antigravity" {
            sessionMonitorTask?.cancel()
            antigravityLogin.start()
            return
        }

        if providerId == "copilot",
           case .runTerminal(let command) = action.kind,
           command == "copilot" {
            sessionMonitorTask?.cancel()
            copilotLogin.start()
            return
        }

        if providerId == "kiro",
           case .runTerminal(let command) = action.kind,
           command == "kiro" {
            sessionMonitorTask?.cancel()
            kiroLogin.start()
            return
        }

        if providerId == "warp" {
            if case .runTerminal(let command) = action.kind, command == "warp-check" {
                performWarpConnectionCheck()
                return
            }
            if case .openApp = action.kind {
                do {
                    try ProviderAuthManager.launch(action)
                } catch {
                    errorMessage = SensitiveDataRedactor.redactedMessage(for: error)
                    return
                }
                statusMessage = L("Warp launched. Checking connection…", "Warp 已启动，正在检查连接…")
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { performWarpConnectionCheck() }
                }
                return
            }
        }

        do {
            try ProviderAuthManager.launch(action)
            beginWatchingForFreshSession()
            statusMessage = L("Login started. Finish sign-in and it will connect automatically.", "登录已启动，完成后会自动连接。")
        } catch {
            errorMessage = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    // MARK: - Session Discovery

    func refreshCandidates() {
        let monitored = ProviderAuthManager.monitoredSessions(for: providerId)
        monitoredSources = monitored.sourceIdentifiers
        monitoredFingerprints = monitored.sessionFingerprints
        monitoredHandles = monitored.accountHandles
        candidates = ProviderAuthManager.unmanagedCandidates(for: providerId)
    }

    func isAlreadyConnected(_ candidate: ProviderAuthCandidate) -> Bool {
        if candidate.identityScope == .accountScoped,
           monitoredSources.contains(candidate.sourceIdentifier) { return true }
        if let fingerprint = candidate.sessionFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           monitoredFingerprints.contains(fingerprint) { return true }
        let normalizedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monitoredHandles.contains(normalizedTitle)
    }

    func handleCodexLoginSuccess() async {
        if let authFileURL = codexLogin.importedAuthFileURL {
            let discoveredCandidates = ProviderAuthManager.discoverCandidates(for: "codex")
            if let matchingCandidate = discoveredCandidates.first(where: { $0.sourcePath == authFileURL.path }) {
                await importCandidate(matchingCandidate)
            } else {
                let candidate = ProviderAuthManager.makeCodexCandidate(authFileURL: authFileURL)
                await importCandidate(candidate)
            }
            await MainActor.run { codexLogin.discardImportedSession() }
            return
        }

        let discoveredCandidates = ProviderAuthManager.discoverCandidates(for: providerId)
        guard let candidate = preferredCodexCandidate(
            from: discoveredCandidates,
            preferredPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath,
            startedAt: codexLogin.startedAt
        ) else {
            await MainActor.run {
                errorMessage = L("Login succeeded in the browser, but AIUsage could not find the new Codex session yet.", "网页登录已经成功，但 AIUsage 暂时还没有找到新的 Codex 会话。")
            }
            return
        }
        await importCandidate(candidate)
    }

    func handleGeminiLoginSuccess() async {
        guard let authFileURL = geminiLogin.importedAuthFileURL else {
            await MainActor.run {
                errorMessage = L("Google sign-in succeeded, but AIUsage could not find the Gemini auth file.", "Google 登录已经成功，但 AIUsage 没有找到 Gemini 的认证文件。")
            }
            return
        }

        let tempCandidate = ProviderAuthCandidate(
            id: "gemini-oauth:\(authFileURL.path)",
            providerId: "gemini",
            sourceIdentifier: "gemini-oauth:\(authFileURL.path)",
            sessionFingerprint: nil,
            title: geminiLogin.accountEmail ?? "Gemini CLI Google Login",
            subtitle: L("Fresh Google login", "新的 Google 登录"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(tempCandidate)
        await MainActor.run { geminiLogin.discardImportedSession() }
    }

    func handleAntigravityLoginSuccess() async {
        guard let authFileURL = antigravityLogin.importedAuthFileURL else {
            await MainActor.run {
                errorMessage = L("Google sign-in succeeded, but AIUsage could not find the Antigravity auth file.", "Google 登录已经成功，但 AIUsage 没有找到 Antigravity 的认证文件。")
            }
            return
        }

        let tempCandidate = ProviderAuthCandidate(
            id: "antigravity-oauth:\(authFileURL.path)",
            providerId: "antigravity",
            sourceIdentifier: "antigravity-oauth:\(antigravityLogin.accountEmail?.lowercased() ?? authFileURL.path)",
            sessionFingerprint: nil,
            title: antigravityLogin.accountEmail ?? "Antigravity Google Login",
            subtitle: L("Fresh Google login", "新的 Google 登录"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(tempCandidate)
        await MainActor.run { antigravityLogin.discardImportedSession() }
    }

    func handleKiroLoginSuccess() async {
        guard let authFileURL = kiroLogin.importedAuthFileURL else {
            await MainActor.run {
                errorMessage = L(
                    "Kiro sign-in succeeded, but AIUsage could not find the auth file.",
                    "Kiro 登录已成功，但 AIUsage 没有找到认证文件。"
                )
            }
            return
        }

        let email = kiroLogin.accountEmail
        let title = email ?? "Kiro Login"
        let sourceId = "kiro-device-flow:\(email?.lowercased() ?? authFileURL.path)"

        let tempCandidate = ProviderAuthCandidate(
            id: "kiro:\(sourceId)",
            providerId: "kiro",
            sourceIdentifier: sourceId,
            sessionFingerprint: nil,
            title: title,
            subtitle: L("AWS SSO Device Flow", "AWS SSO 设备流登录"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(tempCandidate)
        await MainActor.run { kiroLogin.discardImportedSession() }
    }

    func handleCopilotLoginSuccess() async {
        guard let token = copilotLogin.githubToken, !token.isEmpty else {
            await MainActor.run {
                errorMessage = L(
                    "GitHub sign-in succeeded, but AIUsage did not receive a token.",
                    "GitHub 登录已成功，但 AIUsage 未收到 token。"
                )
            }
            return
        }

        let login = copilotLogin.accountLogin
        let email = copilotLogin.accountEmail
        let label = login.map { "@\($0)" } ?? email ?? "GitHub Copilot"
        let sourceId = "gh-device-flow:\(login?.lowercased() ?? email?.lowercased() ?? "default")"

        let candidate = ProviderAuthCandidate(
            id: "copilot:\(sourceId)",
            providerId: "copilot",
            sourceIdentifier: sourceId,
            sessionFingerprint: ProviderAuthManager.tokenFingerprint(token),
            title: label,
            subtitle: L("GitHub Device Flow", "GitHub 设备流登录"),
            detail: email ?? login ?? "",
            modifiedAt: Date(),
            authMethod: .token,
            credentialValue: token,
            sourcePath: nil,
            shouldCopyFile: false,
            identityScope: .accountScoped
        )

        await importCandidate(candidate)
    }

    func preferredCodexCandidate(
        from candidates: [ProviderAuthCandidate],
        preferredPath: String? = nil,
        startedAt: Date? = nil
    ) -> ProviderAuthCandidate? {
        guard providerId == "codex" else { return candidates.first }

        let filteredByTime: [ProviderAuthCandidate]
        if let startedAt {
            let threshold = startedAt.addingTimeInterval(-1)
            let fresh = candidates.filter { ($0.modifiedAt ?? .distantPast) >= threshold }
            filteredByTime = fresh.isEmpty ? candidates : fresh
        } else {
            filteredByTime = candidates
        }

        if let preferredPath {
            return filteredByTime.first(where: { $0.sourcePath == preferredPath })
                ?? filteredByTime.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }.first
        }

        let defaultPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        return filteredByTime.first(where: { $0.sourcePath == defaultPath })
            ?? filteredByTime.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }.first
    }

    func performWarpConnectionCheck() {
        isWorking = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                let provider = WarpProvider()
                let usage = try await provider.fetchUsage()
                let email = usage.accountEmail ?? "Warp User"

                await MainActor.run {
                    statusMessage = L(
                        "Warp detected. Connecting account…",
                        "已检测到 Warp。正在连接账号…"
                    )

                    appState.saveAccount(
                        providerId: "warp",
                        email: email,
                        displayName: "Warp",
                        note: nil,
                        accountId: "warp-auto:\(email.lowercased())"
                    )
                }

                _ = await refreshCoordinator.fetchSingleProvider("warp")
                await MainActor.run {
                    isWorking = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = L(
                        "Warp data not available. Make sure Warp is installed and you are signed in.",
                        "未检测到 Warp 数据。请确认 Warp 已安装且已登录。"
                    )
                }
            }
        }
    }

    func importCandidate(_ candidate: ProviderAuthCandidate) async {
        sessionMonitorTask?.cancel()
        await withWorkingState {
            let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
            let pid = candidate.providerId
            try await MainActor.run {
                try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                statusMessage = L("Account connected.", "账号已连接。")
                refreshCandidates()
            }
            if !shouldSkipImmediateProviderRefresh(for: pid) {
                _ = await refreshCoordinator.fetchSingleProvider(pid)
            }
            await MainActor.run { dismiss() }
        }
    }

    func connectKimiAPIKey() {
        let key = kimiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = L("Enter your Kimi Code API key first.", "请先填写 Kimi Code API Key。")
            return
        }
        let region = kimiAPIRegion
        sessionMonitorTask?.cancel()
        Task {
            await withWorkingState {
                let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                    providerId: "kimi",
                    authMethod: .apiKey,
                    value: key,
                    suggestedLabel: nil,
                    apiRegion: region
                )
                try await MainActor.run {
                    try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                    statusMessage = L("Account connected.", "账号已连接。")
                    kimiAPIKey = ""
                    refreshCandidates()
                }
                _ = await refreshCoordinator.fetchSingleProvider("kimi")
                await MainActor.run { dismiss() }
            }
        }
    }

    func connectMiniMaxAPIKey() {
        let key = miniMaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = L("Enter your MiniMax Subscription Key first.", "请先填写 MiniMax 订阅 Key。")
            return
        }
        let region = miniMaxAPIRegion
        sessionMonitorTask?.cancel()
        Task {
            await withWorkingState {
                let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                    providerId: "minimax",
                    authMethod: .apiKey,
                    value: key,
                    suggestedLabel: nil,
                    apiRegion: region
                )
                try await MainActor.run {
                    try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                    statusMessage = L("Account connected.", "账号已连接。")
                    miniMaxAPIKey = ""
                    refreshCandidates()
                }
                _ = await refreshCoordinator.fetchSingleProvider("minimax")
                await MainActor.run { dismiss() }
            }
        }
    }

    func connectGLMAPIKey() {
        let key = glmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = L("Enter your GLM Coding Plan API key first.", "请先填写 GLM Coding Plan API Key。")
            return
        }
        let region = glmAPIRegion
        sessionMonitorTask?.cancel()
        Task {
            await withWorkingState {
                let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                    providerId: "glm",
                    authMethod: .apiKey,
                    value: key,
                    suggestedLabel: nil,
                    apiRegion: region
                )
                try await MainActor.run {
                    try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                    statusMessage = L("Account connected.", "账号已连接。")
                    glmAPIKey = ""
                    refreshCandidates()
                }
                _ = await refreshCoordinator.fetchSingleProvider("glm")
                await MainActor.run { dismiss() }
            }
        }
    }

    func connectDroidAPIKey() {
        let key = droidAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = L("Enter your Factory API key first.", "请先填写 Factory API Key。")
            return
        }
        sessionMonitorTask?.cancel()
        Task {
            await withWorkingState {
                let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                    providerId: "droid",
                    authMethod: .apiKey,
                    value: key,
                    suggestedLabel: nil
                )
                try await MainActor.run {
                    try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                    statusMessage = L("Account connected.", "账号已连接。")
                    droidAPIKey = ""
                    refreshCandidates()
                }
                _ = await refreshCoordinator.fetchSingleProvider("droid")
                await MainActor.run { dismiss() }
            }
        }
    }

    func importEmbeddedWebSession(cookie: String) async {
        let authMethod: AuthMethod = providerId == "cursor" ? .webSession : .cookie
        sessionMonitorTask?.cancel()
        await withWorkingState {
            let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                providerId: providerId,
                authMethod: authMethod,
                value: cookie,
                suggestedLabel: nil
            )
            try await MainActor.run {
                try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                statusMessage = L("Account connected.", "账号已连接。")
                refreshCandidates()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { dismiss() }
        }
    }

    func withWorkingState(_ operation: @escaping () async throws -> Void) async {
        await MainActor.run { isWorking = true; errorMessage = nil; statusMessage = nil }
        do {
            try await operation()
        } catch {
            await MainActor.run { errorMessage = SensitiveDataRedactor.redactedMessage(for: error) }
        }
        await MainActor.run { isWorking = false }
    }

    func shouldSkipImmediateProviderRefresh(for providerId: String) -> Bool {
        providerId == "codex"
            || providerId == "gemini"
            || providerId == "cursor"
    }

    func beginWatchingForFreshSession() {
        refreshCandidates()
        let baseline = Set(candidates.map(candidateSignature))
        sessionMonitorTask?.cancel()

        sessionMonitorTask = Task {
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }

                let discovered = ProviderAuthManager.discoverCandidates(for: providerId)
                    .filter { !isAlreadyConnected($0) }
                if let candidate = preferredFreshCandidate(from: discovered, baseline: baseline) {
                    // 此处正运行在 sessionMonitorTask 内部，而 importCandidate 第一行会调用
                    // sessionMonitorTask?.cancel()——直接调用会取消「本任务」，导致随后的校验请求
                    // 在已取消的任务里执行并抛出 URLError.cancelled（界面表现为「已取消」）。
                    // 先清空对自身任务的引用，让那次 cancel() 变成空操作，校验请求才不会被自我取消。
                    await MainActor.run { sessionMonitorTask = nil }
                    await importCandidate(candidate)
                    return
                }
            }

            await MainActor.run {
                statusMessage = L("Still waiting. Click login again to retry.", "仍在等待，再次点击登录重试。")
            }
        }
    }

    func preferredFreshCandidate(
        from discovered: [ProviderAuthCandidate],
        baseline: Set<String>
    ) -> ProviderAuthCandidate? {
        let fresh = discovered.filter { !baseline.contains(candidateSignature($0)) }
        let source = fresh.isEmpty ? discovered : fresh
        return source.sorted {
            ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }.first
    }

    func candidateSignature(_ candidate: ProviderAuthCandidate) -> String {
        [
            candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            String(Int(candidate.modifiedAt?.timeIntervalSince1970 ?? 0))
        ].joined(separator: "|")
    }
}
