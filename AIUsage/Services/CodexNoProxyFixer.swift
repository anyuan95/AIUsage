import Foundation
import AppKit
import os.log

// MARK: - Codex No-Proxy Fixer
// 解决「系统代理拦截本地回环导致 codex 报 502」：把 no_proxy / NO_PROXY 写入 codex 自己的
// 环境文件 ~/.codex/.env，让 codex(reqwest) 跳过对 127.0.0.1 / localhost 的代理。
//
// 为什么写 ~/.codex/.env 而不是 shell 配置:
//   - codex 启动时会加载 ~/.codex/.env 并应用其中的环境变量（已实测生效）。
//   - 只影响 codex，不污染用户全局 shell 环境，也和 ~/.codex/config.toml 在同一目录。
//   - 仅作用于本地回环主机，不影响访问外网时走系统代理（外网仍需代理）。
//
// 幂等: 用 sentinel 块包裹，激活时写入 / 替换，停用时整块移除（若文件因此变空则删除）。

private let noProxyFixLog = Logger(subsystem: "com.aiusage.desktop", category: "CodexNoProxy")

enum CodexNoProxyFixer {

    /// 需要跳过代理的主机（仅本地回环）。
    static let bypassHosts = "127.0.0.1,localhost,::1"

    private static let blockBegin = "# >>> AIUSAGE no_proxy (managed, do not edit) >>>"
    private static let blockEnd = "# <<< AIUSAGE no_proxy <<<"

    /// 供 UI 展示 / 手动粘贴的等效环境变量。
    static var exportCommand: String {
        "no_proxy=\"\(bypassHosts)\"\nNO_PROXY=\"\(bypassHosts)\""
    }

    /// UI 展示用路径。
    static let displayEnvPath = "~/.codex/.env"

    // MARK: - Path

    /// 目标文件 ~/.codex/.env（与 CodexConfigManager 一致，使用当前用户主目录）。
    static var envFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".codex/.env")
    }

    // MARK: - Apply / Remove

    /// 幂等写入受管理块（不存在则追加，存在则原地替换）。
    static func apply() throws {
        try CLIConfigWriteGuard.requireAllowed()
        let path = envFilePath
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let stripped = stripManagedBlock(from: existing)

        let block = [
            blockBegin,
            "no_proxy=\"\(bypassHosts)\"",
            "NO_PROXY=\"\(bypassHosts)\"",
            blockEnd
        ].joined(separator: "\n")

        let merged = stripped.isEmpty ? block + "\n" : stripped + "\n\n" + block + "\n"
        try write(merged, to: path)
        noProxyFixLog.info("no_proxy block written to ~/.codex/.env")
    }

    /// 移除受管理块；若文件因此变空则删除整文件（不影响用户自定义内容）。
    static func remove() throws {
        try CLIConfigWriteGuard.requireAllowed()
        let path = envFilePath
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8),
              existing.contains(blockBegin) else {
            return
        }
        let stripped = stripManagedBlock(from: existing)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            noProxyFixLog.info("~/.codex/.env removed (was managed-only)")
        } else {
            try write(stripped + "\n", to: path)
            noProxyFixLog.info("no_proxy block stripped from ~/.codex/.env")
        }
    }

    // MARK: - Clipboard

    static func copyCommandToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportCommand, forType: .string)
    }

    // MARK: - Internal Helpers

    private static func write(_ content: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = content.data(using: .utf8) else {
            throw NoProxyFixError.failedToWrite
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            noProxyFixLog.error("Failed to write ~/.codex/.env: \(String(describing: error), privacy: .public)")
            throw NoProxyFixError.failedToWrite
        }
    }

    /// 去掉已存在的受管理块（含起止 sentinel 行），并清理首尾多余空行。
    private static func stripManagedBlock(from content: String) -> String {
        var out: [String] = []
        var skipping = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == blockBegin { skipping = true; continue }
            if trimmed == blockEnd { skipping = false; continue }
            if skipping { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }
}

enum NoProxyFixError: LocalizedError {
    case failedToWrite

    var errorDescription: String? {
        AppSettings.shared.t(
            "Failed to write ~/.codex/.env.",
            "写入 ~/.codex/.env 失败。"
        )
    }
}
