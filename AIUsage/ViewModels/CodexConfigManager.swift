import Foundation
import os.log

// MARK: - Codex Config Manager
// 管理 ~/.codex/config.toml：以「外科式合并」方式注入受管理的 [model_providers.aiusage-proxy]
// 块，并把顶层 model / model_provider 指向本地代理；停用时从备份完整还原原文。
//
// 数据来源/写入目标: ~/.codex/config.toml
// 工作方式: 纯字符串处理，不引入 TOML 第三方库。激活前把「干净原文」备份到
//          config.toml.aiusage.bak（备份即真相源，保证重复激活幂等），还原即覆盖回原文。
// 安全: config.toml 可能含 token，写入后恢复 0600 权限。

private let codexConfigLog = Logger(subsystem: "com.aiusage.desktop", category: "CodexConfig")

enum CodexConfigError: LocalizedError {
    case unreadableConfig
    case failedToCreateDirectory
    case failedToWriteFile
    case failedToRestore

    var errorDescription: String? {
        switch self {
        case .unreadableConfig:
            return AppSettings.shared.t("Codex config.toml is unreadable.", "Codex config.toml 无法读取。")
        case .failedToCreateDirectory:
            return AppSettings.shared.t("Failed to create the Codex config directory.", "创建 Codex 配置目录失败。")
        case .failedToWriteFile:
            return AppSettings.shared.t("Failed to write Codex config.toml.", "写入 Codex config.toml 失败。")
        case .failedToRestore:
            return AppSettings.shared.t("Failed to restore Codex config.toml from backup.", "从备份还原 Codex config.toml 失败。")
        }
    }
}

final class CodexConfigManager {
    static let shared = CodexConfigManager()

    /// 受管理的 provider id。Codex 保留 openai/ollama/lmstudio，aiusage-proxy 不冲突。
    static let providerId = "aiusage-proxy"

    private let fileManager = FileManager.default

    // MARK: - Managed Block Sentinels

    private static let headerBegin = "# >>> AIUSAGE-CODEX-PROXY BEGIN (managed, do not edit) >>>"
    private static let headerEnd = "# <<< AIUSAGE-CODEX-PROXY END <<<"
    private static let baseBegin = "# >>> AIUSAGE-CODEX-BASE BEGIN (managed, do not edit) >>>"
    private static let baseEnd = "# <<< AIUSAGE-CODEX-BASE END <<<"
    private static let providerBegin = "# >>> AIUSAGE-CODEX-PROVIDER BEGIN (managed, do not edit) >>>"
    private static let providerEnd = "# <<< AIUSAGE-CODEX-PROVIDER END <<<"

    // MARK: - Paths

    var configPath: String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".codex/config.toml")
    }

    private var backupPath: String {
        configPath + ".aiusage.bak"
    }

    // MARK: - State

    /// 当前 config.toml 是否处于受管理（已注入代理）状态。
    var isManaged: Bool {
        guard let content = try? readConfigIfExists() else { return false }
        return content.contains(Self.headerBegin)
    }

    /// 是否存在我们的备份（代表代理激活态/未正常还原）。
    var hasBackup: Bool {
        fileManager.fileExists(atPath: backupPath)
    }

    // MARK: - Activation

    /// 注入受管理的代理配置：把顶层 model/model_provider 指向 aiusage-proxy，并追加 provider 块。
    /// - Parameters:
    ///   - baseURL: 本地代理地址（含 /v1，Codex 会在其后拼 /responses）。
    ///   - bearerToken: 通过 experimental_bearer_token 直接下发，Codex 以 Bearer 头发给本地代理。
    ///   - model: 写入顶层 model 的模型名（同时作为上游模型 / 定价键）。
    ///   - globalTOML: 全局通用配置基底（启用时传入；否则 nil）。
    ///   - nodeTOML: 当前节点的额外 TOML（覆盖全局同名顶层键 / 同名表）。
    func activate(
        baseURL: String,
        bearerToken: String,
        model: String,
        globalTOML: String? = nil,
        nodeTOML: String? = nil
    ) throws {
        try CLIConfigWriteGuard.requireAllowed()
        // 备份即真相源：若已有备份，原文以备份为准（保证重复激活幂等，不会把脏文件当原文）。
        let pristine: String?
        if hasBackup {
            pristine = (try? String(contentsOfFile: backupPath, encoding: .utf8)) ?? ""
        } else if fileManager.fileExists(atPath: configPath) {
            let current = try readConfigIfExists() ?? ""
            // 防御：万一当前文件里残留旧的受管理块，先剥离再作为原文备份。
            let clean = stripManagedBlocks(from: current)
            try writeBackup(clean)
            pristine = clean
        } else {
            pristine = nil
        }

        let merged = mergeBaseFragments(global: globalTOML ?? "", node: nodeTOML ?? "")
        let injected = injectManagedConfig(
            into: pristine ?? "",
            baseURL: baseURL,
            bearerToken: bearerToken,
            model: model,
            baseTopLevel: merged.topLevel,
            baseTables: merged.tables
        )
        try writeConfig(injected)
        codexConfigLog.info("Codex config.toml proxy block injected (provider=\(Self.providerId, privacy: .public), baseKeys=\(merged.topLevel.count), baseTables=\(merged.tables.count))")
    }

    // MARK: - Standalone Config (CODEX_HOME launch command)

    /// 生成一份独立的 config.toml 文本（**不写入** `~/.codex`），供「复制启动命令」的 CODEX_HOME 模式使用。
    /// 注入与 `activate` 完全一致的受管理块 + 全局/节点 TOML 合并，但作用在空原文上；
    /// 因此用 `CODEX_HOME=<dir> codex` 启动的 Codex 行为与激活态等价，且不污染用户真实 config.toml。
    func makeStandaloneConfig(
        baseURL: String,
        bearerToken: String,
        model: String,
        globalTOML: String? = nil,
        nodeTOML: String? = nil
    ) -> String {
        let merged = mergeBaseFragments(global: globalTOML ?? "", node: nodeTOML ?? "")
        return injectManagedConfig(
            into: "",
            baseURL: baseURL,
            bearerToken: bearerToken,
            model: model,
            baseTopLevel: merged.topLevel,
            baseTables: merged.tables
        )
    }

    // MARK: - Deactivation

    /// 还原 config.toml：有备份则整文覆盖回原文并删除备份；无备份则剥离受管理块（必要时删文件）。
    func restore() throws {
        try CLIConfigWriteGuard.requireAllowed()
        if hasBackup {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
                try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
                applyRestrictivePermissions()
                try? fileManager.removeItem(atPath: backupPath)
                codexConfigLog.info("Codex config.toml restored from backup")
            } catch {
                codexConfigLog.error("Failed to restore Codex config.toml from backup: \(String(describing: error), privacy: .public)")
                throw CodexConfigError.failedToRestore
            }
            return
        }

        // 无备份：可能是我们新建的文件（仅含受管理块），或本就未受管理。
        guard let current = try readConfigIfExists() else { return }
        let stripped = stripManagedBlocks(from: current)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fileManager.removeItem(atPath: configPath)
            codexConfigLog.info("Codex config.toml removed (was managed-only, no backup)")
        } else {
            try writeConfig(stripped)
            codexConfigLog.info("Codex config.toml managed blocks stripped (no backup)")
        }
    }

    // MARK: - String Transform

    /// 在干净原文上注入受管理配置。
    /// 结构（保证所有顶层键都在任何 [table] 之前，符合 TOML 语义）：
    ///   HEADER(model + model_provider) → BASE 顶层键块 → 用户 body（去重）→ BASE 表块 → PROVIDER 块。
    /// 去重：删除 body 中与受管理块冲突的顶层键（model/model_provider + BASE 顶层键）与同名 [table]，
    /// 避免 TOML 重复键/重复表解析错误（节点/全局配置在激活态优先生效；停用从备份完整还原）。
    func injectManagedConfig(
        into original: String,
        baseURL: String,
        bearerToken: String,
        model: String,
        baseTopLevel: [String] = [],
        baseTables: [String] = []
    ) -> String {
        let clean = stripManagedBlocks(from: original)

        // 收集 BASE 块要覆盖的顶层键名 / 表头，用于从 body 剥离冲突项。
        let baseKeyNames = Set(baseTopLevel.compactMap { topLevelKeyName(of: $0) })
        let baseTableHeaders = Set(baseTables.compactMap { firstTableHeader(in: $0) })

        var body: [String] = []
        var seenTable = false
        var skipTableHeader: String? // 正在跳过的冲突表（直到下一个表头）
        for line in clean.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                seenTable = true
                let header = normalizedTableHeader(trimmed)
                skipTableHeader = baseTableHeaders.contains(header) ? header : nil
                if skipTableHeader != nil { continue }
            } else if skipTableHeader != nil {
                continue // 跳过冲突表内的行
            }
            if !seenTable {
                if isTopLevelKey(trimmed, key: "model") || isTopLevelKey(trimmed, key: "model_provider") {
                    continue
                }
                if let key = topLevelKeyName(of: trimmed), baseKeyNames.contains(key) {
                    continue // BASE 块会重新定义该键
                }
            }
            body.append(line)
        }

        var header = [
            Self.headerBegin,
            "model = \(tomlString(model))",
            "model_provider = \(tomlString(Self.providerId))",
            Self.headerEnd,
        ]
        if !baseTopLevel.isEmpty {
            header.append("")
            header.append(Self.baseBegin)
            header.append(contentsOf: baseTopLevel)
            header.append(Self.baseEnd)
        }
        header.append("")
        let headerText = header.joined(separator: "\n")

        var tail: [String] = []
        if !baseTables.isEmpty {
            tail.append("")
            tail.append(Self.baseBegin)
            tail.append(contentsOf: baseTables)
            tail.append(Self.baseEnd)
        }
        tail.append("")
        tail.append(Self.providerBegin)
        tail.append("[model_providers.\(Self.providerId)]")
        tail.append("name = \(tomlString("AIUsage Proxy"))")
        tail.append("base_url = \(tomlString(baseURL))")
        tail.append("wire_api = \(tomlString("responses"))")
        tail.append("experimental_bearer_token = \(tomlString(bearerToken))")
        tail.append(Self.providerEnd)
        tail.append("")
        let tailText = tail.joined(separator: "\n")

        let bodyText = body.joined(separator: "\n")
        return headerText + bodyText + tailText
    }

    /// 移除全部受管理块（header / base / provider，含起止 sentinel 行）。
    func stripManagedBlocks(from content: String) -> String {
        let begins: Set<String> = [Self.headerBegin, Self.baseBegin, Self.providerBegin]
        let ends: Set<String> = [Self.headerEnd, Self.baseEnd, Self.providerEnd]
        var result: [String] = []
        var skipping = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if begins.contains(trimmed) {
                skipping = true
                continue
            }
            if ends.contains(trimmed) {
                skipping = false
                continue
            }
            if skipping { continue }
            result.append(line)
        }
        // 去掉因剥离产生的首尾多余空行。
        return result.joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    // MARK: - Base Fragment Merge (global + node, node wins)

    /// 把全局通用配置与节点额外 TOML 按「顶层键 / 表头」粒度合并，节点覆盖全局同名项。
    /// 返回可直接注入的 (顶层键行, 表块文本)。
    func mergeBaseFragments(global: String, node: String) -> (topLevel: [String], tables: [String]) {
        let g = splitFragment(global)
        let n = splitFragment(node)

        var topOrder: [String] = []
        var topMap: [String: String] = [:]
        for (key, line) in g.top + n.top {
            if topMap[key] == nil { topOrder.append(key) }
            topMap[key] = line // 后者（节点）覆盖
        }
        let topLevel = topOrder.compactMap { topMap[$0] }

        var tableOrder: [String] = []
        var tableMap: [String: String] = [:]
        for (header, block) in g.tables + n.tables {
            if tableMap[header] == nil { tableOrder.append(header) }
            tableMap[header] = block
        }
        let tables = tableOrder.compactMap { tableMap[$0] }

        return (topLevel, tables)
    }

    /// 把 TOML 片段拆为「顶层键行」与「表块（表头+其后行，至下个表头/EOF）」。
    /// 顶层作用域的注释/空行忽略；表块按原样保留（含注释）。
    private func splitFragment(_ fragment: String) -> (top: [(String, String)], tables: [(String, String)]) {
        var top: [(String, String)] = []
        var tables: [(String, String)] = []
        var currentHeader: String?
        var currentBlock: [String] = []

        func flush() {
            if let header = currentHeader {
                tables.append((header, currentBlock.joined(separator: "\n")))
            }
            currentHeader = nil
            currentBlock = []
        }

        for raw in fragment.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                flush()
                currentHeader = normalizedTableHeader(trimmed)
                currentBlock = [raw]
                continue
            }
            if currentHeader != nil {
                currentBlock.append(raw)
            } else if let key = topLevelKeyName(of: trimmed) {
                top.append((key, raw))
            }
        }
        flush()
        return (top, tables)
    }

    /// 提取顶层 `key = value` 行的键名；非键值行（空行/注释/表头）返回 nil。
    private func topLevelKeyName(of trimmed: String) -> String? {
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// 规范化表头：去掉首尾空白与外层括号内容前后的空白，返回括号内文本（如 model_providers.foo）。
    private func normalizedTableHeader(_ trimmed: String) -> String {
        var s = trimmed
        while s.hasPrefix("[") { s.removeFirst() }
        while s.hasSuffix("]") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 取一个表块文本里的首个表头（用于去重比对）。
    private func firstTableHeader(in block: String) -> String? {
        for raw in block.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return normalizedTableHeader(trimmed) }
        }
        return nil
    }

    // MARK: - Import Parsing (cc-switch / 外部 config.toml)

    /// 从一份完整 config.toml（如 cc-switch 的 Codex 供应商配置）抽取导入所需信息。
    struct ImportedCodexConfig {
        /// 激活 provider（顶层 `model_provider` 指向的 `[model_providers.<id>]`）的 `base_url`，可能含 `/v1`。
        var providerBaseURL: String?
        /// 顶层 `model`。
        var model: String?
        /// 剥离 `model` / `model_provider` / 所有 `[model_providers.*]` 后的剩余 TOML
        /// （保真用户其余配置：注释、`model_reasoning_effort`、`[mcp_servers.*]` 等）。
        var extraTOML: String
    }

    /// 解析外部 config.toml：抽取激活 provider 的 `base_url`、顶层 `model`，并把其余用户配置
    /// （去掉 AIUsage 托管的 `model` / `model_provider` / `[model_providers.*]`）整理为 extraTOML，
    /// 供节点保真保存。激活时这些托管项由 `injectManagedConfig` 重新注入指向本地代理。
    func parseImportedConfig(_ toml: String) -> ImportedCodexConfig {
        var activeProvider: String?
        var model: String?
        var providerBaseURLs: [String: String] = [:]

        var currentHeader: String?
        for raw in toml.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                currentHeader = normalizedTableHeader(trimmed)
                continue
            }
            if currentHeader == nil {
                if isTopLevelKey(trimmed, key: "model_provider") {
                    activeProvider = tomlInlineStringValue(of: trimmed)
                } else if isTopLevelKey(trimmed, key: "model") {
                    model = tomlInlineStringValue(of: trimmed)
                }
            } else if let header = currentHeader,
                      header.hasPrefix("model_providers."),
                      isTopLevelKey(trimmed, key: "base_url") {
                // 形如 model_providers.<id>(.env...)：取最外层 provider id（首段）。
                let suffix = header.dropFirst("model_providers.".count)
                let providerId = suffix.split(separator: ".", maxSplits: 1).first.map(String.init) ?? String(suffix)
                if providerBaseURLs[providerId] == nil {
                    providerBaseURLs[providerId] = tomlInlineStringValue(of: trimmed)
                }
            }
        }

        let baseURL: String?
        if let active = activeProvider, let url = providerBaseURLs[active] {
            baseURL = url
        } else {
            baseURL = providerBaseURLs.values.first
        }

        return ImportedCodexConfig(
            providerBaseURL: baseURL,
            model: model,
            extraTOML: stripImportManagedKeys(from: toml)
        )
    }

    /// 剥离顶层 `model` / `model_provider` 与所有 `[model_providers.*]` 表，保留其余原文（含注释）。
    private func stripImportManagedKeys(from toml: String) -> String {
        var result: [String] = []
        var currentHeader: String?
        var skippingTable = false
        for raw in toml.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                let header = normalizedTableHeader(trimmed)
                currentHeader = header
                if header == "model_providers" || header.hasPrefix("model_providers.") {
                    skippingTable = true
                    continue
                }
                skippingTable = false
                result.append(raw)
                continue
            }
            if skippingTable { continue }
            if currentHeader == nil,
               isTopLevelKey(trimmed, key: "model") || isTopLevelKey(trimmed, key: "model_provider") {
                continue
            }
            result.append(raw)
        }
        return result.joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    /// 取 `key = "value"` / `key = 'value'` 行的字符串值（去引号、basic string 反转义）。非字符串返回 nil。
    private func tomlInlineStringValue(of trimmed: String) -> String? {
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            let afterQuote = value.dropFirst()
            guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
            let inner = String(afterQuote[afterQuote.startIndex..<end])
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .nilIfBlank
        }
        if value.hasPrefix("'") {
            let afterQuote = value.dropFirst()
            guard let end = afterQuote.firstIndex(of: "'") else { return nil }
            return String(afterQuote[afterQuote.startIndex..<end]).nilIfBlank
        }
        return nil
    }

    // MARK: - Helpers

    /// 判断某行是否为指定顶层 key 的赋值（精确匹配，避免误伤 model_reasoning_effort 等）。
    private func isTopLevelKey(_ trimmed: String, key: String) -> Bool {
        guard trimmed.hasPrefix(key) else { return false }
        let rest = trimmed.dropFirst(key.count)
        // key 后必须紧跟可选空白再接 '='。
        let afterKey = rest.drop(while: { $0 == " " || $0 == "\t" })
        return afterKey.first == "="
    }

    /// 生成 TOML basic string（转义反斜杠与双引号）。
    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func readConfigIfExists() throws -> String? {
        guard fileManager.fileExists(atPath: configPath) else { return nil }
        do {
            return try String(contentsOfFile: configPath, encoding: .utf8)
        } catch {
            codexConfigLog.error("Failed to read Codex config.toml: \(String(describing: error), privacy: .public)")
            throw CodexConfigError.unreadableConfig
        }
    }

    private func writeBackup(_ content: String) throws {
        do {
            try content.data(using: .utf8)?.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
        } catch {
            codexConfigLog.error("Failed to write Codex config backup: \(String(describing: error), privacy: .public)")
            throw CodexConfigError.failedToWriteFile
        }
    }

    private func writeConfig(_ content: String) throws {
        let dir = (configPath as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            codexConfigLog.error("Failed to create Codex config directory: \(String(describing: error), privacy: .public)")
            throw CodexConfigError.failedToCreateDirectory
        }
        do {
            try content.data(using: .utf8)?.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            applyRestrictivePermissions()
        } catch {
            codexConfigLog.error("Failed to write Codex config.toml: \(String(describing: error), privacy: .public)")
            throw CodexConfigError.failedToWriteFile
        }
    }

    /// config.toml 可能含 token，写入后恢复 0600 权限。
    private func applyRestrictivePermissions() {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
    }
}
