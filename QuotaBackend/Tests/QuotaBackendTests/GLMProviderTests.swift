import XCTest
@testable import QuotaBackend

final class GLMProviderTests: XCTestCase {
    func testAuthorizationHeaderOmitsBearerPrefix() {
        XCTAssertEqual(GLMProvider.authorizationHeaderValue(from: "  abc.def  "), "abc.def")
        XCTAssertEqual(GLMProvider.authorizationHeaderValue(from: "Bearer abc.def"), "abc.def")
        XCTAssertEqual(GLMProvider.authorizationHeaderValue(from: "bearer xyz"), "xyz")
    }

    func testParsesCreditLimitWindows() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(Self.creditLimitJSON)

        XCTAssertEqual(parsed.planName, "Lite")
        XCTAssertEqual(parsed.session?.entitlement, 2000)
        XCTAssertEqual(parsed.session?.remaining, 1929)
        XCTAssertEqual(parsed.weekly?.entitlement, 10000)
        XCTAssertEqual(parsed.weekly?.remaining, 9929)
        XCTAssertNotNil(parsed.session?.resetAt)
        XCTAssertNotNil(parsed.weekly?.resetAt)
        XCTAssertEqual(parsed.session?.usedPercent ?? 0, 71.0 / 2000.0 * 100, accuracy: 0.01)
    }

    func testParsesLegacyTokenLimitWindows() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(Self.tokenLimitJSON)

        XCTAssertEqual(parsed.planName, "Pro")
        XCTAssertEqual(parsed.session?.entitlement, 12000)
        XCTAssertEqual(parsed.weekly?.entitlement, 60000)
    }

    func testClassifiesByResetWhenUnitMissing() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 53.0, "nextResetTime": 2_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 44.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TIME_LIMIT", "percentage": 7.0]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 44)
        XCTAssertEqual(parsed.weekly?.usedPercent, 53)
    }

    func testOldPlanSingleTierFallsBackToFiveHour() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 2.0, "nextResetTime": 1_774_967_594_803],
            ["type": "TIME_LIMIT", "percentage": 0.0]
        ], level: "lite"))

        XCTAssertEqual(parsed.session?.usedPercent, 2)
        XCTAssertNil(parsed.weekly)
    }

    func testMissingResetTimeIsFiveHourWhenWeeklyHasReset() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 25.0, "nextResetTime": 2_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 0.0]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 0)
        XCTAssertNil(parsed.session?.resetAt)
        XCTAssertEqual(parsed.weekly?.usedPercent, 25)
        XCTAssertNotNil(parsed.weekly?.resetAt)
    }

    func testUnitOverridesResetOrderWhenWeeklyResetsSooner() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 6, "number": 7, "percentage": 42.0, "nextResetTime": 1_000_003_600_000],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 1.0, "nextResetTime": 1_000_018_000_000]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 1)
        XCTAssertEqual(parsed.weekly?.usedPercent, 42)
    }

    func testWeeklyUnitSixNumberOneVariant() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 30.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10.0, "nextResetTime": 2_000_000_000_000]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 10)
        XCTAssertEqual(parsed.weekly?.usedPercent, 30)
    }

    func testTypeIsCaseInsensitive() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "tokens_limit", "percentage": 12.0, "nextResetTime": 1_000_000_000_000],
            ["type": "Tokens_Limit", "percentage": 34.0, "nextResetTime": 2_000_000_000_000]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 12)
        XCTAssertEqual(parsed.weekly?.usedPercent, 34)
    }

    func testUnknownUnitFallsBackToResetOrder() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 9, "percentage": 44.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "unit": 9, "percentage": 53.0, "nextResetTime": 2_000_000_000_000]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 44)
        XCTAssertEqual(parsed.weekly?.usedPercent, 53)
    }

    func testDuplicateUnitClassificationFillsOtherSlot() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 20.0, "nextResetTime": 2_000_000_000_000]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 10)
        XCTAssertEqual(parsed.weekly?.usedPercent, 20)
    }

    func testMoreThanTwoTokenLimitsKeepsFirstTwo() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 1.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 2.0, "nextResetTime": 2_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 3.0, "nextResetTime": 3_000_000_000_000]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 1)
        XCTAssertEqual(parsed.weekly?.usedPercent, 2)
    }

    func testInvalidPercentageFallsBackToZero() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": "invalid", "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": NSNull(), "nextResetTime": 2_000_000_000_000]
        ]))

        XCTAssertEqual(parsed.session?.usedPercent, 0)
        XCTAssertEqual(parsed.weekly?.usedPercent, 0)
    }

    func testRejectsEmptyPayAsYouGoPayload() {
        XCTAssertThrowsError(try GLMCodingPlanQuotaParser.parse(["code": 200, "success": true, "data": ["limits": []]])) { error in
            let providerError = error as? ProviderError
            XCTAssertEqual(providerError?.code, "empty_usage")
        }
    }

    func testIgnoresTimeLimitOnlyEntries() {
        XCTAssertThrowsError(try GLMCodingPlanQuotaParser.parse([
            "code": 200,
            "success": true,
            "data": [
                "level": "lite",
                "limits": [
                    ["type": "TIME_LIMIT", "unit": 3, "number": 5, "usage": 20, "currentValue": 1, "remaining": 19, "percentage": 5]
                ]
            ]
        ])) { error in
            XCTAssertEqual((error as? ProviderError)?.code, "empty_usage")
        }
    }

    func testGenericBusinessErrorIsNotAuthFailure() {
        XCTAssertFalse(GLMCodingPlanQuotaParser.isAuthFailure([
            "success": false,
            "code": 500,
            "msg": "Operation failed"
        ]))
        XCTAssertTrue(GLMCodingPlanQuotaParser.isAuthFailure([
            "success": false,
            "code": 401,
            "msg": "unauthorized"
        ]))
    }

    func testRegistryIncludesGLM() {
        XCTAssertEqual(ProviderRegistry.provider(for: "glm")?.id, "glm")
        XCTAssertTrue(ProviderRegistry.allProviders().map(\.id).contains("glm"))
    }

    private func wrapLimits(_ limits: [[String: Any]], level: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["limits": limits]
        if let level {
            data["level"] = level
        }
        return [
            "code": 200,
            "success": true,
            "data": data
        ]
    }

    private static let creditLimitJSON: [String: Any] = [
        "code": 200,
        "msg": "Operation successful",
        "success": true,
        "data": [
            "level": "lite",
            "limits": [
                [
                    "type": "CREDIT_LIMIT",
                    "unit": 3,
                    "number": 5,
                    "usage": 2000,
                    "currentValue": 71,
                    "remaining": 1929,
                    "percentage": 3,
                    "nextResetTime": 1_786_073_946_574
                ],
                [
                    "type": "CREDIT_LIMIT",
                    "unit": 6,
                    "number": 1,
                    "usage": 10000,
                    "currentValue": 71,
                    "remaining": 9929,
                    "percentage": 1,
                    "nextResetTime": 1_786_660_486_998
                ]
            ]
        ]
    ]

    private static let tokenLimitJSON: [String: Any] = [
        "code": 200,
        "success": true,
        "data": [
            "level": "pro",
            "limits": [
                [
                    "type": "TOKENS_LIMIT",
                    "unit": 3,
                    "number": 5,
                    "usage": 12000,
                    "currentValue": 100,
                    "remaining": 11900,
                    "percentage": 1,
                    "nextResetTime": 1_786_073_946_574
                ],
                [
                    "type": "TOKENS_LIMIT",
                    "unit": 6,
                    "number": 1,
                    "usage": 60000,
                    "currentValue": 100,
                    "remaining": 59900,
                    "percentage": 1,
                    "nextResetTime": 1_786_660_486_998
                ]
            ]
        ]
    ]
}
