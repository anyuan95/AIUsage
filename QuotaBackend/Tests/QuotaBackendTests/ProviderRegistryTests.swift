import XCTest
@testable import QuotaBackend

final class ProviderRegistryTests: XCTestCase {
    func testRegistryContainsExpectedProvidersInStableOrder() {
        let ids = ProviderRegistry.allProviders().map(\.id)

        XCTAssertEqual(
            ids,
            [
                "antigravity",
                "claude",
                "codex-cost",
                "codex",
                "copilot",
                "cursor",
                "droid",
                "gemini",
                "glm",
                "kimi",
                "kiro",
                "minimax",
                "opencode",
                "warp"
            ]
        )
    }

    func testLookupReturnsRequestedProviderOnly() {
        let provider = ProviderRegistry.provider(for: "gemini")

        XCTAssertNotNil(provider)
        XCTAssertEqual(provider?.id, "gemini")
        XCTAssertEqual(ProviderRegistry.providers(for: ["gemini"]).map(\.id), ["gemini"])
    }
}
