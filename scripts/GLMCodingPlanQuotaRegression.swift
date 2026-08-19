import Foundation

private enum RegressionFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RegressionFailure.failed(message) }
}

private func wrapLimits(_ limits: [[String: Any]], level: String? = nil) -> [String: Any] {
    var data: [String: Any] = ["limits": limits]
    if let level { data["level"] = level }
    return ["code": 200, "success": true, "data": data]
}

@main
private struct GLMCodingPlanQuotaRegression {
    static func main() throws {
        try testAuthorizationHeaderOmitsBearerPrefix()
        try testParsesCreditLimitWindows()
        try testClassifiesByResetWhenUnitMissing()
        try testOldPlanSingleTierFallsBackToFiveHour()
        try testMissingResetTimeIsFiveHourWhenWeeklyHasReset()
        try testUnitOverridesResetOrderWhenWeeklyResetsSooner()
        try testWeeklyUnitSixNumberOneVariant()
        try testTypeIsCaseInsensitive()
        try testUnknownUnitFallsBackToResetOrder()
        try testDuplicateUnitClassificationFillsOtherSlot()
        try testMoreThanTwoTokenLimitsKeepsFirstTwo()
        try testInvalidPercentageFallsBackToZero()
        try testRejectsEmptyPayAsYouGoPayload()
        try testIgnoresTimeLimitOnlyEntries()
        try testGenericBusinessErrorIsNotAuthFailure()
        print("GLM Coding Plan quota parser regression passed.")
    }

    static func testAuthorizationHeaderOmitsBearerPrefix() throws {
        try expect(GLMProvider.authorizationHeaderValue(from: "  abc.def  ") == "abc.def", "trim key")
        try expect(GLMProvider.authorizationHeaderValue(from: "Bearer abc.def") == "abc.def", "strip Bearer")
        try expect(GLMProvider.authorizationHeaderValue(from: "bearer xyz") == "xyz", "strip bearer")
    }

    static func testParsesCreditLimitWindows() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse([
            "code": 200,
            "success": true,
            "data": [
                "level": "lite",
                "limits": [
                    [
                        "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                        "usage": 2000, "currentValue": 71, "remaining": 1929,
                        "percentage": 3, "nextResetTime": 1_786_073_946_574
                    ],
                    [
                        "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
                        "usage": 10000, "currentValue": 71, "remaining": 9929,
                        "percentage": 1, "nextResetTime": 1_786_660_486_998
                    ]
                ]
            ]
        ])
        try expect(parsed.planName == "Lite", "plan name")
        try expect(parsed.session?.entitlement == 2000, "session entitlement")
        try expect(parsed.session?.remaining == 1929, "session remaining")
        try expect(parsed.weekly?.entitlement == 10000, "weekly entitlement")
        try expect(abs((parsed.session?.usedPercent ?? 0) - (71.0 / 2000.0 * 100)) < 0.01, "session used percent")
    }

    static func testClassifiesByResetWhenUnitMissing() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 53.0, "nextResetTime": 2_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 44.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TIME_LIMIT", "percentage": 7.0]
        ]))
        try expect(parsed.session?.usedPercent == 44, " nearer reset is 5h")
        try expect(parsed.weekly?.usedPercent == 53, " later reset is weekly")
    }

    static func testOldPlanSingleTierFallsBackToFiveHour() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 2.0, "nextResetTime": 1_774_967_594_803],
            ["type": "TIME_LIMIT", "percentage": 0.0]
        ], level: "lite"))
        try expect(parsed.session?.usedPercent == 2, "old plan is 5h")
        try expect(parsed.weekly == nil, "old plan has no weekly")
    }

    static func testMissingResetTimeIsFiveHourWhenWeeklyHasReset() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 25.0, "nextResetTime": 2_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 0.0]
        ]))
        try expect(parsed.session?.usedPercent == 0, "no reset -> 5h")
        try expect(parsed.session?.resetAt == nil, "5h has no reset")
        try expect(parsed.weekly?.usedPercent == 25, "reset entry is weekly")
    }

    static func testUnitOverridesResetOrderWhenWeeklyResetsSooner() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 6, "number": 7, "percentage": 42.0, "nextResetTime": 1_000_003_600_000],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 1.0, "nextResetTime": 1_000_018_000_000]
        ]))
        try expect(parsed.session?.usedPercent == 1, "unit 3 is 5h even if reset is later")
        try expect(parsed.weekly?.usedPercent == 42, "unit 6 is weekly even if reset is sooner")
    }

    static func testWeeklyUnitSixNumberOneVariant() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 30.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10.0, "nextResetTime": 2_000_000_000_000]
        ]))
        try expect(parsed.session?.usedPercent == 10, "unit 3")
        try expect(parsed.weekly?.usedPercent == 30, "unit 6 number 1")
    }

    static func testTypeIsCaseInsensitive() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "tokens_limit", "percentage": 12.0, "nextResetTime": 1_000_000_000_000],
            ["type": "Tokens_Limit", "percentage": 34.0, "nextResetTime": 2_000_000_000_000]
        ]))
        try expect(parsed.session?.usedPercent == 12, "case-insensitive 5h")
        try expect(parsed.weekly?.usedPercent == 34, "case-insensitive weekly")
    }

    static func testUnknownUnitFallsBackToResetOrder() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 9, "percentage": 44.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "unit": 9, "percentage": 53.0, "nextResetTime": 2_000_000_000_000]
        ]))
        try expect(parsed.session?.usedPercent == 44, "unknown unit nearer reset")
        try expect(parsed.weekly?.usedPercent == 53, "unknown unit later reset")
    }

    static func testDuplicateUnitClassificationFillsOtherSlot() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 20.0, "nextResetTime": 2_000_000_000_000]
        ]))
        try expect(parsed.session?.usedPercent == 10, "first unit 3")
        try expect(parsed.weekly?.usedPercent == 20, "duplicate fills weekly")
    }

    static func testMoreThanTwoTokenLimitsKeepsFirstTwo() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": 1.0, "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 2.0, "nextResetTime": 2_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": 3.0, "nextResetTime": 3_000_000_000_000]
        ]))
        try expect(parsed.session?.usedPercent == 1, "keep first")
        try expect(parsed.weekly?.usedPercent == 2, "keep second")
    }

    static func testInvalidPercentageFallsBackToZero() throws {
        let parsed = try GLMCodingPlanQuotaParser.parse(wrapLimits([
            ["type": "TOKENS_LIMIT", "percentage": "invalid", "nextResetTime": 1_000_000_000_000],
            ["type": "TOKENS_LIMIT", "percentage": NSNull(), "nextResetTime": 2_000_000_000_000]
        ]))
        try expect(parsed.session?.usedPercent == 0, "invalid percentage")
        try expect(parsed.weekly?.usedPercent == 0, "null percentage")
    }

    static func testRejectsEmptyPayAsYouGoPayload() throws {
        do {
            _ = try GLMCodingPlanQuotaParser.parse(["code": 200, "success": true, "data": ["limits": []]])
            throw RegressionFailure.failed("empty limits should fail")
        } catch let error as ProviderError {
            try expect(error.code == "empty_usage", "empty usage code")
        }
    }

    static func testIgnoresTimeLimitOnlyEntries() throws {
        do {
            _ = try GLMCodingPlanQuotaParser.parse(wrapLimits([
                ["type": "TIME_LIMIT", "unit": 3, "percentage": 5]
            ], level: "lite"))
            throw RegressionFailure.failed("TIME_LIMIT only should fail")
        } catch let error as ProviderError {
            try expect(error.code == "empty_usage", "time limit only")
        }
    }

    static func testGenericBusinessErrorIsNotAuthFailure() throws {
        try expect(
            GLMCodingPlanQuotaParser.isAuthFailure(["success": false, "code": 500, "msg": "Operation failed"]) == false,
            "generic error is not auth"
        )
        try expect(
            GLMCodingPlanQuotaParser.isAuthFailure(["success": false, "code": 401, "msg": "unauthorized"]) == true,
            "401 is auth"
        )
    }
}
