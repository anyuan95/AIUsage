import Foundation

// Test-only app model shims. This file is compiled together with the real
// ClaudeDesktopProfileStore.swift, so the transaction implementation under
// test is exactly the one shipped by AIUsage.
final class AppSettings {
    static let shared = AppSettings()
    var allowCLIConfigWrites = true
    func t(_ en: String, _ zh: String) -> String { en }
}

enum CLIConfigWriteError: Error {
    case disabled
}

enum CLIConfigWriteGuard {
    static var isAllowed: Bool { AppSettings.shared.allowCLIConfigWrites }

    static func requireAllowed() throws {
        guard isAllowed else { throw CLIConfigWriteError.disabled }
    }
}

struct RegressionMappedModel { let name: String }
struct RegressionModelMapping {
    let bigModel: RegressionMappedModel
    let middleModel: RegressionMappedModel
    let smallModel: RegressionMappedModel
}
struct ProxyConfiguration {
    let modelLibrary: [RegressionMappedModel]
    let defaultModel: String
    let modelMapping: RegressionModelMapping
}

enum RegressionFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

@main
enum ClaudeDesktopProfileTransactionRegression {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-claude-desktop-profile-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try exactRestoreScenario(root: root.appendingPathComponent("restore"), fileManager: fileManager)
        try externalOwnerScenario(root: root.appendingPathComponent("conflict"), fileManager: fileManager)
        try sharedPreferenceMutationScenario(root: root.appendingPathComponent("preferences"), fileManager: fileManager)
        try staleSelfConflictScenario(root: root.appendingPathComponent("stale-self-conflict"), fileManager: fileManager)
        try externalEditScenario(root: root.appendingPathComponent("external-edit"), fileManager: fileManager)
        try blockedCLIConfigWritesScenario(root: root.appendingPathComponent("blocked-writes"), fileManager: fileManager)
        print("Claude Desktop profile transaction regression passed")
    }

    private static func blockedCLIConfigWritesScenario(root: URL, fileManager: FileManager) throws {
        let paths = ClaudeDesktopProfileStore.Paths(home: root)
        let store = ClaudeDesktopProfileStore(fileManager: fileManager, paths: paths)
        let catalog = [
            ClaudeDesktopCatalogEntry(
                id: "claude-opus-aiusage-v1-model-large-a1",
                upstreamModel: "provider/model-large",
                displayName: "Model Large",
                supports1M: false
            )
        ]

        AppSettings.shared.allowCLIConfigWrites = false
        do {
            try store.connect(
                baseURL: "https://localhost:14403/claude-desktop",
                clientKey: "desktop-key-blocked",
                catalog: catalog
            )
            throw RegressionFailure.assertion("connect succeeded while CLI config writes were disabled")
        } catch is CLIConfigWriteError {
            // expected
        }
        try require(
            !fileManager.fileExists(atPath: paths.journal.path),
            "journal was written while CLI config writes were disabled"
        )
        try require(
            !fileManager.fileExists(atPath: paths.profile.path),
            "Desktop profile was written while CLI config writes were disabled"
        )

        AppSettings.shared.allowCLIConfigWrites = true
        try write(Data("{}\n".utf8), to: paths.normalConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{}\n".utf8), to: paths.threePConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{\"entries\":[]}\n".utf8), to: paths.meta, fileManager: fileManager, permissions: 0o600)
        try store.connect(
            baseURL: "https://localhost:14403/claude-desktop",
            clientKey: "desktop-key-connected",
            catalog: catalog
        )
        let profileBefore = try Data(contentsOf: paths.profile)
        let journalBefore = try Data(contentsOf: paths.journal)

        AppSettings.shared.allowCLIConfigWrites = false
        defer { AppSettings.shared.allowCLIConfigWrites = true }

        do {
            try store.refresh(
                baseURL: "https://localhost:14403/claude-desktop",
                clientKey: "desktop-key-refreshed",
                catalog: catalog
            )
            throw RegressionFailure.assertion("refresh succeeded while CLI config writes were disabled")
        } catch is CLIConfigWriteError {
            // expected
        }
        try require(try Data(contentsOf: paths.profile) == profileBefore, "refresh wrote the Desktop profile while disabled")
        try require(try Data(contentsOf: paths.journal) == journalBefore, "refresh wrote the journal while disabled")

        do {
            _ = try store.disconnect()
            throw RegressionFailure.assertion("disconnect succeeded while CLI config writes were disabled")
        } catch is CLIConfigWriteError {
            // expected
        }
        try require(try Data(contentsOf: paths.profile) == profileBefore, "disconnect wrote the Desktop profile while disabled")

        var journal = try jsonObject(at: paths.journal)
        journal["phase"] = "applying"
        try write(
            try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]),
            to: paths.journal,
            fileManager: fileManager,
            permissions: 0o600
        )
        try store.recoverInterruptedApplyIfNeeded()
        let recovered = try jsonObject(at: paths.journal)
        try require(recovered["phase"] as? String == "applying", "recover mutated the journal while CLI config writes were disabled")
        try require(try Data(contentsOf: paths.profile) == profileBefore, "recover wrote the Desktop profile while disabled")
    }

    private static func exactRestoreScenario(root: URL, fileManager: FileManager) throws {
        let paths = ClaudeDesktopProfileStore.Paths(home: root)
        let originalNormal = Data("{\"deploymentMode\":\"consumer\",\"keep\":1}\n".utf8)
        let originalThreeP = Data("{\"deploymentMode\":\"consumer\",\"keep3p\":true}\n".utf8)
        let originalMeta = Data("{\"entries\":[{\"id\":\"other\",\"name\":\"Other Tool\"}],\"appliedId\":\"other\",\"keepMeta\":7}\n".utf8)
        try write(originalNormal, to: paths.normalConfig, fileManager: fileManager, permissions: 0o640)
        try write(originalThreeP, to: paths.threePConfig, fileManager: fileManager, permissions: 0o600)
        try write(originalMeta, to: paths.meta, fileManager: fileManager, permissions: 0o600)

        let store = ClaudeDesktopProfileStore(fileManager: fileManager, paths: paths)
        let firstCatalog = [
            ClaudeDesktopCatalogEntry(id: "claude-opus-aiusage-v1-model-large-a1", upstreamModel: "provider/model-large", displayName: "Model Large", supports1M: false),
            ClaudeDesktopCatalogEntry(id: "claude-haiku-aiusage-v1-model-fast-b2", upstreamModel: "provider/model-fast", displayName: "Model Fast", supports1M: true),
        ]
        try store.connect(baseURL: "https://localhost:14403/claude-desktop", clientKey: "desktop-key-a", catalog: firstCatalog)
        try require(store.status().isOwnedByAIUsage, "AIUsage profile was not selected")
        try require(fileManager.fileExists(atPath: paths.journal.path), "restore journal was not written")
        try require(permissions(of: paths.journal, fileManager: fileManager) == 0o600, "journal permissions are not 0600")

        let profile = try jsonObject(at: paths.profile)
        try require(profile["inferenceGatewayBaseUrl"] as? String == "https://localhost:14403/claude-desktop", "gateway URL mismatch")
        try require(profile["inferenceGatewayApiKey"] as? String == "desktop-key-a", "gateway key mismatch")
        let profileModels = profile["inferenceModels"] as? [[String: Any]]
        try require(profileModels?.count == 2, "model catalog mismatch")
        try require(profileModels?[0]["labelOverride"] as? String == "Model Large", "display label mismatch")
        try require(profileModels?[1]["supports1m"] as? Bool == true, "1M option mismatch")

        // Connecting again while AIUsage owns the profile is an in-place
        // refresh; the original pre-connect snapshot must remain unchanged.
        try store.connect(
            baseURL: "https://localhost:14403/claude-desktop",
            clientKey: "desktop-key-b",
            catalog: [ClaudeDesktopCatalogEntry(id: "claude-sonnet-aiusage-v1-new-model-c3", upstreamModel: "new/model", displayName: "New Model", supports1M: false)]
        )
        try require(try store.disconnect(), "disconnect did not report an exact restore")
        try require(try Data(contentsOf: paths.normalConfig) == originalNormal, "normal config was not restored byte-for-byte")
        try require(try Data(contentsOf: paths.threePConfig) == originalThreeP, "3P config was not restored byte-for-byte")
        try require(try Data(contentsOf: paths.meta) == originalMeta, "profile metadata was not restored byte-for-byte")
        try require(!fileManager.fileExists(atPath: paths.profile.path), "new AIUsage profile file was not removed")
        try require(!fileManager.fileExists(atPath: paths.journal.path), "journal was not removed after restore")
        try require(permissions(of: paths.normalConfig, fileManager: fileManager) == 0o640, "original permissions were not restored")
    }

    private static func externalOwnerScenario(root: URL, fileManager: FileManager) throws {
        let paths = ClaudeDesktopProfileStore.Paths(home: root)
        try write(Data("{}\n".utf8), to: paths.normalConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{}\n".utf8), to: paths.threePConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{\"entries\":[]}\n".utf8), to: paths.meta, fileManager: fileManager, permissions: 0o600)
        let store = ClaudeDesktopProfileStore(fileManager: fileManager, paths: paths)
        try store.connect(
            baseURL: "https://localhost:14403/claude-desktop",
            clientKey: "desktop-key",
            catalog: [ClaudeDesktopCatalogEntry(id: "claude-opus-aiusage-v1-real-model-d4", upstreamModel: "real/model", displayName: "Model", supports1M: false)]
        )

        var meta = try jsonObject(at: paths.meta)
        meta["appliedId"] = "external-tool-profile"
        let externalBytes = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try write(externalBytes, to: paths.meta, fileManager: fileManager, permissions: 0o600)

        do {
            _ = try store.disconnect()
            throw RegressionFailure.assertion("disconnect overwrote another tool's active profile")
        } catch ClaudeDesktopProfileError.profileOwnedByAnotherTool {
            let after = try jsonObject(at: paths.meta)
            try require(after["appliedId"] as? String == "external-tool-profile", "external profile selection was overwritten")
        }

        // Clicking Connect is explicit authority to take over. It must rebase
        // the restore point onto the profile that is active now, not remain
        // permanently wedged behind the stale conflict journal.
        try store.connect(
            baseURL: "https://localhost:14403/claude-desktop",
            clientKey: "desktop-key-2",
            catalog: [ClaudeDesktopCatalogEntry(id: "claude-sonnet-4-6-aiusage-v1", upstreamModel: "new/model", displayName: "AIUsage Sonnet", supports1M: false)]
        )
        try require(store.status().isOwnedByAIUsage, "explicit reconnect did not take over the profile")
        _ = try store.disconnect()
        let restoredExternal = try jsonObject(at: paths.meta)
        try require(restoredExternal["appliedId"] as? String == "external-tool-profile", "disconnect did not restore the profile selected before takeover")
    }

    private static func sharedPreferenceMutationScenario(root: URL, fileManager: FileManager) throws {
        let paths = ClaudeDesktopProfileStore.Paths(home: root)
        try write(Data("{\"deploymentMode\":\"consumer\",\"normalPreference\":1}\n".utf8), to: paths.normalConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{\"deploymentMode\":\"consumer\",\"theme\":\"light\"}\n".utf8), to: paths.threePConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{\"entries\":[],\"metaPreference\":1}\n".utf8), to: paths.meta, fileManager: fileManager, permissions: 0o600)
        let store = ClaudeDesktopProfileStore(fileManager: fileManager, paths: paths)
        let catalog = [ClaudeDesktopCatalogEntry(id: "claude-sonnet-4-6-aiusage-v1", upstreamModel: "real/model", displayName: "AIUsage Sonnet", supports1M: false)]
        try store.connect(baseURL: "https://localhost:14403/claude-desktop", clientKey: "desktop-key", catalog: catalog)

        // Claude Desktop updates unrelated preferences while AIUsage is
        // connected. These changes must neither create a false conflict nor be
        // erased by Disconnect.
        var normal = try jsonObject(at: paths.normalConfig)
        normal["normalPreference"] = 2
        try write(try JSONSerialization.data(withJSONObject: normal, options: [.sortedKeys]), to: paths.normalConfig, fileManager: fileManager, permissions: 0o600)
        var threeP = try jsonObject(at: paths.threePConfig)
        threeP["theme"] = "dark"
        try write(try JSONSerialization.data(withJSONObject: threeP, options: [.sortedKeys]), to: paths.threePConfig, fileManager: fileManager, permissions: 0o600)
        var meta = try jsonObject(at: paths.meta)
        var entries = meta["entries"] as? [[String: Any]] ?? []
        entries.append(["id": "new-external-profile", "name": "New External Profile"])
        meta["entries"] = entries
        meta["metaPreference"] = 2
        try write(try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]), to: paths.meta, fileManager: fileManager, permissions: 0o600)

        // Reconnect repairs only owned fields and adopts the latest unrelated
        // preferences into the journal baseline.
        try store.connect(baseURL: "https://localhost:14403/claude-desktop", clientKey: "desktop-key-2", catalog: catalog)
        _ = try store.disconnect()

        let restoredNormal = try jsonObject(at: paths.normalConfig)
        let restoredThreeP = try jsonObject(at: paths.threePConfig)
        let restoredMeta = try jsonObject(at: paths.meta)
        try require(restoredNormal["deploymentMode"] as? String == "consumer", "normal deployment mode was not restored")
        try require(restoredNormal["normalPreference"] as? Int == 2, "normal preference written by Desktop was lost")
        try require(restoredThreeP["deploymentMode"] as? String == "consumer", "3P deployment mode was not restored")
        try require(restoredThreeP["theme"] as? String == "dark", "3P preference written by Desktop was lost")
        let restoredEntries = restoredMeta["entries"] as? [[String: Any]] ?? []
        try require(restoredEntries.contains(where: { $0["id"] as? String == "new-external-profile" }), "new external profile entry was lost")
        try require(restoredMeta["metaPreference"] as? Int == 2, "metadata preference written by Desktop was lost")
    }

    private static func externalEditScenario(root: URL, fileManager: FileManager) throws {
        let paths = ClaudeDesktopProfileStore.Paths(home: root)
        try write(Data("{}\n".utf8), to: paths.normalConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{}\n".utf8), to: paths.threePConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{\"entries\":[]}\n".utf8), to: paths.meta, fileManager: fileManager, permissions: 0o600)
        let store = ClaudeDesktopProfileStore(fileManager: fileManager, paths: paths)
        try store.connect(
            baseURL: "https://localhost:14403/claude-desktop",
            clientKey: "desktop-key",
            catalog: [ClaudeDesktopCatalogEntry(id: "claude-opus-4-6-aiusage-v1-1", upstreamModel: "real/model", displayName: "Model", supports1M: false)]
        )

        var profile = try jsonObject(at: paths.profile)
        profile["externalField"] = "must-survive"
        let externalBytes = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        try write(externalBytes, to: paths.profile, fileManager: fileManager, permissions: 0o600)

        // A user-requested repair must not adopt the whole profile as an
        // AIUsage-owned blob. Unknown fields still belong to Desktop/other
        // integrations and must survive the eventual disconnect.
        try store.connect(
            baseURL: "https://localhost:14403/claude-desktop",
            clientKey: "desktop-key-repaired",
            catalog: [ClaudeDesktopCatalogEntry(id: "claude-opus-4-6-aiusage-v1-1", upstreamModel: "real/model", displayName: "Model", supports1M: false)]
        )

        _ = try store.disconnect()
        let after = try jsonObject(at: paths.profile)
        try require(after["externalField"] as? String == "must-survive", "unowned profile field was overwritten")
        try require(after["inferenceGatewayBaseUrl"] == nil, "AIUsage base URL was not removed")
        try require(after["inferenceModels"] == nil, "AIUsage model catalog was not removed")
    }

    /// Reproduces the real upgrade case: an older AIUsage build marked its
    /// own selected profile as an external conflict after Claude Desktop
    /// rewrote unrelated preferences. Explicit Connect must repair and adopt
    /// that journal instead of permanently rejecting the user.
    private static func staleSelfConflictScenario(root: URL, fileManager: FileManager) throws {
        let paths = ClaudeDesktopProfileStore.Paths(home: root)
        try write(Data("{\"deploymentMode\":\"consumer\"}\n".utf8), to: paths.normalConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{\"deploymentMode\":\"consumer\",\"theme\":\"light\"}\n".utf8), to: paths.threePConfig, fileManager: fileManager, permissions: 0o600)
        try write(Data("{\"entries\":[]}\n".utf8), to: paths.meta, fileManager: fileManager, permissions: 0o600)
        let store = ClaudeDesktopProfileStore(fileManager: fileManager, paths: paths)
        let catalog = [ClaudeDesktopCatalogEntry(
            id: "claude-sonnet-4-6-aiusage-v1",
            upstreamModel: "node/model-middle",
            displayName: "AIUsage Sonnet",
            supports1M: false
        )]
        try store.connect(baseURL: "https://localhost:14403/claude-desktop", clientKey: "desktop-key", catalog: catalog)

        var threeP = try jsonObject(at: paths.threePConfig)
        threeP["theme"] = "dark"
        try write(
            try JSONSerialization.data(withJSONObject: threeP, options: [.sortedKeys]),
            to: paths.threePConfig,
            fileManager: fileManager,
            permissions: 0o600
        )
        var journal = try jsonObject(at: paths.journal)
        journal["phase"] = "externalConflict"
        try write(
            try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]),
            to: paths.journal,
            fileManager: fileManager,
            permissions: 0o600
        )

        try store.connect(
            baseURL: "https://localhost:14403/claude-desktop",
            clientKey: "desktop-key-repaired",
            catalog: catalog
        )
        try require(store.status().isOwnedByAIUsage, "stale self-conflict did not reconnect")
        _ = try store.disconnect()
        let restoredThreeP = try jsonObject(at: paths.threePConfig)
        try require(restoredThreeP["deploymentMode"] as? String == "consumer", "stale conflict did not restore deployment mode")
        try require(restoredThreeP["theme"] as? String == "dark", "stale conflict repair erased Desktop preferences")
    }

    private static func write(_ data: Data, to url: URL, fileManager: FileManager, permissions: UInt16) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw RegressionFailure.assertion("invalid JSON object at \(url.lastPathComponent)")
        }
        return object
    }

    private static func permissions(of url: URL, fileManager: FileManager) throws -> UInt16 {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw RegressionFailure.assertion(message) }
    }
}
