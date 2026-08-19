import SwiftUI
import AppKit
import os.log

// MARK: - Codex config.toml Editor
// 直接查看/编辑 live ~/.codex/config.toml。提供 TOML 语法高亮（NSTextView 着色）+ 轻量语法检查
// （行级 lint，非完整 TOML 解析）+ 纯文本保存（0600 权限）。检测到 AIUsage 受管理代理块时给出
// 明确提示，避免误改 sentinel 之间的内容。

private let codexConfigEditorLog = Logger(subsystem: "com.aiusage.desktop", category: "CodexConfigEditor")

struct CodexConfigEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var text = ""
    @State private var hasUnsavedChanges = false
    @State private var showSaveSuccess = false
    @State private var isLoadingFile = false
    @State private var saveError: String?
    @State private var containsManagedBlock = false
    @State private var check: TOMLCheckResult = .ok

    private static var configPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".codex/config.toml")
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if containsManagedBlock {
                managedNotice
                Divider()
            }
            TOMLSyntaxTextView(text: $text) {
                guard !isLoadingFile else { return }
                hasUnsavedChanges = true
                showSaveSuccess = false
                check = TOMLLinter.validate(text)
            }
            .background(Color(nsColor: .textBackgroundColor))
            checkBar
            if let saveError {
                Divider()
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .onAppear { loadFile() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            ProviderIconView("codex", size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("~/.codex/config.toml")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(L("Live configuration file for Codex", "Codex 当前生效的配置文件"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if showSaveSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L("Saved", "已保存"))
                        .foregroundStyle(.green)
                }
                .font(.caption.weight(.medium))
                .transition(.opacity)
            }

            if hasUnsavedChanges {
                Text(L("Unsaved", "未保存"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var managedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.indigo)
            Text(L(
                "Contains an AIUsage-managed proxy block (auto-restored on deactivation). Avoid editing lines between the sentinel comments.",
                "包含 AIUsage 受管理代理块（停用时自动还原）。请勿改动 sentinel 注释之间的内容。"
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.indigo.opacity(0.06))
    }

    // MARK: - Syntax check bar

    @ViewBuilder
    private var checkBar: some View {
        Divider()
        HStack(spacing: 6) {
            switch check {
            case .ok:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(L("TOML syntax OK", "TOML 语法检查通过"))
                    .foregroundStyle(.secondary)
            case let .issue(line, message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L("Line \(line): \(message)", "第 \(line) 行：\(message)"))
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text(L("Close", "关闭"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Spacer()

            if !settings.allowCLIConfigWrites {
                Text(CLIConfigWriteError.disabled.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button {
                saveFile()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(L("Save", "保存"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(!hasUnsavedChanges || !settings.allowCLIConfigWrites)
            .opacity(hasUnsavedChanges && settings.allowCLIConfigWrites ? 1 : 0.5)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - File I/O

    private func loadFile() {
        isLoadingFile = true
        let path = Self.configPath
        if let data = FileManager.default.contents(atPath: path),
           let str = String(data: data, encoding: .utf8) {
            text = str
        } else {
            text = ""
        }
        containsManagedBlock = text.contains("AIUSAGE-CODEX")
        check = TOMLLinter.validate(text)
        hasUnsavedChanges = false
        DispatchQueue.main.async { isLoadingFile = false }
    }

    private func saveFile() {
        guard let data = text.data(using: .utf8) else {
            saveError = L("Invalid text encoding", "文本编码无效")
            return
        }
        let path = Self.configPath
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try CLIConfigWriteGuard.requireAllowed()
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            // config.toml 可能含 token，恢复 0600 权限（与 CodexConfigManager 一致）。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            saveError = nil
            containsManagedBlock = text.contains("AIUSAGE-CODEX")
            hasUnsavedChanges = false
            withAnimation(.easeInOut(duration: 0.25)) { showSaveSuccess = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.3)) { showSaveSuccess = false }
            }
            codexConfigEditorLog.info("config.toml saved via local editor")
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Codex Global Config Editor (fragment)
// 编辑 CodexGlobalConfig.tomlText —— 激活节点/订阅时按顶层键合并注入 config.toml 的「通用配置基底」。
// 与 live config.toml 编辑器复用同一套 TOML 高亮 + 轻量检查；保存进 NodeProfileStore（JSON 容器）。

struct CodexGlobalConfigEditorView: View {
    @ObservedObject var store: NodeProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hasUnsavedChanges = false
    @State private var showSaveSuccess = false
    @State private var isLoading = false
    @State private var check: TOMLCheckResult = .ok

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            TOMLSyntaxTextView(text: $text) {
                guard !isLoading else { return }
                hasUnsavedChanges = true
                showSaveSuccess = false
                check = TOMLLinter.validate(text)
            }
            .background(Color(nsColor: .textBackgroundColor))
            checkBar
            Divider()
            footerBar
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 580)
        .onAppear { loadFromStore() }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Common Config", "通用配置"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L(
                    "Base TOML fragment merged into config.toml on activation. Node values override.",
                    "激活节点/订阅时按顶层键合并写入 config.toml，节点配置优先级更高。"
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if showSaveSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("Saved", "已保存")).foregroundStyle(.green)
                }
                .font(.caption.weight(.medium))
                .transition(.opacity)
            }

            if hasUnsavedChanges {
                Text(L("Unsaved", "未保存"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var checkBar: some View {
        Divider()
        HStack(spacing: 6) {
            switch check {
            case .ok:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(L("TOML syntax OK", "TOML 语法检查通过")).foregroundStyle(.secondary)
            case let .issue(line, message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L("Line \(line): \(message)", "第 \(line) 行：\(message)")).foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var footerBar: some View {
        HStack {
            Button { dismiss() } label: {
                Text(L("Close", "关闭"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                saveToStore()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                    Text(L("Save", "保存")).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(!hasUnsavedChanges)
            .opacity(hasUnsavedChanges ? 1 : 0.5)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func loadFromStore() {
        isLoading = true
        text = store.codexGlobalConfig.tomlText
        check = TOMLLinter.validate(text)
        hasUnsavedChanges = false
        DispatchQueue.main.async { isLoading = false }
    }

    private func saveToStore() {
        store.codexGlobalConfig.tomlText = text
        store.saveCodexGlobalConfig()
        hasUnsavedChanges = false
        withAnimation(.easeInOut(duration: 0.25)) { showSaveSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.3)) { showSaveSuccess = false }
        }
        codexConfigEditorLog.info("Codex global config fragment saved")
    }
}

// MARK: - TOML Syntax Highlighting (NSTextView)

/// 轻量 TOML 高亮编辑器：包一层 NSTextView，按行做词法着色（注释/段头/键/字符串/数字/布尔）。
/// config.toml 体量极小，每次变更全量重着色成本可忽略。
struct TOMLSyntaxTextView: NSViewRepresentable {
    @Binding var text: String
    var onChange: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = TOMLHighlighter.font
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.typingAttributes = [
            .font: TOMLHighlighter.font,
            .foregroundColor: NSColor.textColor
        ]
        textView.string = text
        TOMLHighlighter.apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            TOMLHighlighter.apply(to: textView)
            textView.selectedRanges = ranges
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: TOMLSyntaxTextView
        init(_ parent: TOMLSyntaxTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            TOMLHighlighter.apply(to: textView)
            parent.onChange?()
        }
    }
}

// MARK: - TOML Highlighter (line lexer)

enum TOMLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static let commentColor = NSColor.systemGray
    private static let sectionColor = NSColor.systemPurple
    private static let keyColor = NSColor.systemBlue
    private static let stringColor = NSColor.systemRed
    private static let literalColor = NSColor.systemTeal

    /// 重新着色整个文档。逐行词法分析，正确区分字符串内的 `#` 与真正的行内注释。
    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: fullRange)
        source.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            highlightLine(source, lineRange: lineRange, storage: storage)
        }
        storage.endEditing()
    }

    private static func highlightLine(_ source: NSString, lineRange: NSRange, storage: NSTextStorage) {
        let line = source.substring(with: lineRange)
        let base = lineRange.location

        // 1) 找到行内注释起点（字符串外的第一个 #）。
        var inSingle = false
        var inDouble = false
        var commentStart: Int?
        let chars = Array(line)
        for (i, ch) in chars.enumerated() {
            switch ch {
            case "\"" where !inSingle: inDouble.toggle()
            case "'" where !inDouble: inSingle.toggle()
            case "#" where !inSingle && !inDouble:
                commentStart = i
            default:
                break
            }
            if commentStart != nil { break }
        }

        let codeEnd = commentStart ?? chars.count
        if let cs = commentStart, cs < chars.count {
            storage.addAttribute(.foregroundColor, value: commentColor,
                                 range: NSRange(location: base + cs, length: chars.count - cs))
        }
        guard codeEnd > 0 else { return }

        let codeStr = String(chars[0..<codeEnd])
        let trimmed = codeStr.trimmingCharacters(in: .whitespaces)

        // 2) 段头 [section] / [[array]]。
        if trimmed.hasPrefix("[") {
            storage.addAttribute(.foregroundColor, value: sectionColor,
                                 range: NSRange(location: base, length: codeEnd))
            return
        }

        // 3) key = value：键名着蓝，值里高亮字符串/数字/布尔。
        if let eq = codeStr.firstIndex(of: "=") {
            let keyLen = codeStr.distance(from: codeStr.startIndex, to: eq)
            storage.addAttribute(.foregroundColor, value: keyColor,
                                 range: NSRange(location: base, length: keyLen))
            let valueStart = base + keyLen + 1
            let valueLen = codeEnd - keyLen - 1
            if valueLen > 0 {
                highlightValue(String(chars[(keyLen + 1)..<codeEnd]),
                               base: valueStart, storage: storage)
            }
        }
    }

    private static func highlightValue(_ value: String, base: Int, storage: NSTextStorage) {
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" || ch == "'" {
                let quote = ch
                let start = i
                i += 1
                while i < chars.count && chars[i] != quote { i += 1 }
                let end = min(i, chars.count - 1)
                storage.addAttribute(.foregroundColor, value: stringColor,
                                     range: NSRange(location: base + start, length: end - start + 1))
                i += 1
            } else if ch.isNumber || ((ch == "t" || ch == "f") && isWordBoundary(chars, i)) {
                let start = i
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "." || chars[i] == "_" {
                    i += 1
                }
                storage.addAttribute(.foregroundColor, value: literalColor,
                                     range: NSRange(location: base + start, length: i - start))
            } else {
                i += 1
            }
        }
    }

    private static func isWordBoundary(_ chars: [Character], _ i: Int) -> Bool {
        i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
    }
}

// MARK: - TOML Linter (lightweight)

enum TOMLCheckResult: Equatable {
    case ok
    case issue(line: Int, message: String)
}

/// 行级宽松校验：只标记明显问题（段头括号不闭合、引号成对失衡），不做完整 TOML 解析，
/// 避免对数组跨行 / 多行字符串等合法写法产生误报。
enum TOMLLinter {
    static func validate(_ text: String) -> TOMLCheckResult {
        let lines = text.components(separatedBy: "\n")
        for (idx, raw) in lines.enumerated() {
            let lineNo = idx + 1
            // 去掉行内注释（字符串外的 #）。
            let code = stripComment(raw)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // 段头括号闭合检查。
            if trimmed.hasPrefix("[") {
                let opens = trimmed.prefix { $0 == "[" }.count
                guard trimmed.hasSuffix(String(repeating: "]", count: opens)) else {
                    return .issue(line: lineNo, message: L("unbalanced section brackets", "段头括号不闭合"))
                }
                continue
            }

            // 引号成对检查（剔除多行字符串/字面量定界符后计奇偶）。
            if hasUnbalancedQuotes(code) {
                return .issue(line: lineNo, message: L("unbalanced quotes", "引号不成对"))
            }
        }
        return .ok
    }

    private static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""
        for ch in line {
            if ch == "\"", !inSingle { inDouble.toggle() }
            else if ch == "'", !inDouble { inSingle.toggle() }
            else if ch == "#", !inSingle, !inDouble { break }
            result.append(ch)
        }
        return result
    }

    private static func hasUnbalancedQuotes(_ code: String) -> Bool {
        // 先剔除三引号定界符，避免对多行字符串误报。
        let stripped = code
            .replacingOccurrences(of: "\"\"\"", with: "")
            .replacingOccurrences(of: "'''", with: "")
        let doubles = stripped.filter { $0 == "\"" }.count
        let singles = stripped.filter { $0 == "'" }.count
        return doubles % 2 != 0 || singles % 2 != 0
    }
}
