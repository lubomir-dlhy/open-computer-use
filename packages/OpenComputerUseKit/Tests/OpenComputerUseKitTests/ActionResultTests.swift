@testable import OpenComputerUseKit
import XCTest

final class ActionResultTests: XCTestCase {
    private let before = [
        "0 standard window Form",
        "\t1 text field Name, Value: Ada",
        "\t2 checkbox Subscribe Value: off",
        "\t3 list",
        "\t\t4 row First",
        "first row detail",
        "\t\t5 row Second",
        "\t\t\t6 text Second",
        "7 menu bar",
    ]

    func testEntriesKeepContinuationLinesAndParents() {
        let entries = treeDiffEntries(lines: before, indices: [0, 1, 2, 3, 4, nil, 5, 6, 7])
        XCTAssertEqual(entries.map(\.index), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(entries.map(\.parent), [nil, 0, 0, 0, 3, 3, 5, nil])
        XCTAssertEqual(entries[4].body, "4 row First\nfirst row detail")
    }

    func testDiffReportsChangedAddedAndRemovedSubtrees() {
        let after = [
            "0 standard window Form",
            "\t1 text field Name, Value: Ada",
            "\t2 checkbox Subscribe Value: on",
            "\t3 list",
            "\t\t4 row First",
            "first row detail",
            "\t8 sheet Confirm",
            "\t\t9 button OK",
            "7 menu bar",
        ]
        let diff = TreeDiff(
            before: treeDiffEntries(lines: before, indices: [0, 1, 2, 3, 4, nil, 5, 6, 7]),
            after: treeDiffEntries(lines: after, indices: [0, 1, 2, 3, 4, nil, 8, 9, 7])
        )
        XCTAssertEqual(diff.rendered(), [
            "~ 2 checkbox Subscribe Value: on",
            "+ 8 sheet Confirm (in 0)",
            "+ \t9 button OK",
            "- 5 row Second (and 1 inside)",
        ])
    }

    func testUnchangedTreeIsEmptyAndLongDiffsAreCapped() {
        let entries = treeDiffEntries(lines: before, indices: [0, 1, 2, 3, 4, nil, 5, 6, 7])
        XCTAssertTrue(TreeDiff(before: entries, after: entries).isEmpty)

        let added = (100..<110).map { "\t\($0) button B\($0)" }
        let diff = TreeDiff(before: entries, after: treeDiffEntries(lines: before + added, indices: [0, 1, 2, 3, 4, nil, 5, 6, 7] + Array(100..<110)))
        let lines = diff.rendered(maxEntries: 3)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.last, "… 7 more changes; call get_app_state for the full tree.")
    }

    func testRemovalsKeepRoomInALongDiff() {
        let before = ["0 window"] + (1...10).map { "\t\($0) text Old \($0)" }
        let after = ["0 window"] + (100..<120).map { "\t\($0) text New \($0)" }
        let diff = TreeDiff(
            before: treeDiffEntries(lines: before, indices: [0] + Array(1...10)),
            after: treeDiffEntries(lines: after, indices: [0] + Array(100..<120))
        )
        let lines = diff.rendered(maxEntries: 10)
        XCTAssertEqual(lines.filter { $0.hasPrefix("+ ") }.count, 8)
        XCTAssertEqual(lines.filter { $0.hasPrefix("- ") }.count, 2)
        XCTAssertEqual(lines.last, "… 20 more changes; call get_app_state for the full tree.")
    }

    func testEntriesFallBackToLeadingIndexWithoutLineIndices() {
        let entries = treeDiffEntries(lines: ["0 window", "    1 button OK"], indices: [])
        XCTAssertEqual(entries.map(\.index), [0, 1])
        XCTAssertEqual(entries.map(\.parent), [nil, 0])
    }

    func testDefaultsFollowEnvironment() {
        XCTAssertEqual(ActionObservation.defaults(environment: [:]), ActionObservation(state: .diff, screenshot: false))
        XCTAssertEqual(ActionObservation.defaults(environment: ["OPEN_COMPUTER_USE_ACTION_RESULT": "full"]),
                       ActionObservation(state: .full, screenshot: true))
        XCTAssertEqual(ActionObservation.defaults(environment: ["OPEN_COMPUTER_USE_ACTION_RESULT": "none"]).state, .none)
        XCTAssertEqual(ActionObservation.defaults(environment: ["OPEN_COMPUTER_USE_ACTION_READ_BACK": "0"]).state, .none)
        XCTAssertFalse(ActionObservation.defaults(environment: ["OPEN_COMPUTER_USE_ACTION_READ_BACK": "0"]).readsBack)
    }

    func testWaitConditionParsesAbsence() {
        XCTAssertNil(WaitCondition(""))
        XCTAssertNil(WaitCondition("!"))
        let gone = WaitCondition("!Loading")
        XCTAssertEqual(gone?.text, "Loading")
        XCTAssertEqual(gone?.absent, true)
        XCTAssertEqual(WaitCondition("Done")?.absent, false)
    }

    func testDispatcherRejectsBadResultOptionsBeforeActing() {
        let dispatcher = ComputerUseToolDispatcher()
        let invalid: [[String: Any]] = [
            ["state": "tree"],
            ["screenshot": "yes"],
            ["wait_for": ""],
            ["wait_timeout": 0],
            ["wait_timeout": 31],
        ]
        for extra in invalid {
            let arguments = ["app": "missing-test-app", "key": "Tab"].merging(extra) { $1 }
            XCTAssertThrowsError(try dispatcher.callTool(name: "press_key", arguments: arguments), "\(extra)") {
                guard case ComputerUseError.invalidArguments = $0 else {
                    return XCTFail("unexpected error \($0) for \(extra)")
                }
            }
        }
    }

    func testBatchValidatesStepsBeforeRunningAny() {
        let dispatcher = ComputerUseToolDispatcher()
        let invalid: [[String: Any]] = [
            ["app": "A", "steps": []],
            ["app": "A", "steps": [["tool": "get_app_state"]]],
            ["app": "A", "steps": [["key": "Tab"]]],
            ["app": "A", "steps": [["tool": "press_key", "key": "Tab", "app": "B"]]],
            ["app": "A", "steps": [["tool": "press_key", "key": "Tab", "wait_timeout": -1]]],
            ["app": "A", "steps": Array(repeating: ["tool": "press_key", "key": "Tab"], count: 51)],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try dispatcher.callTool(name: "batch", arguments: arguments)) {
                guard case ComputerUseError.invalidArguments = $0 else {
                    return XCTFail("unexpected error \($0)")
                }
            }
        }
    }

    func testEveryActionToolTakesResultOptions() {
        let tools = Dictionary(uniqueKeysWithValues: ToolDefinitions.all.map { ($0.name, $0) })
        for name in ComputerUseToolDispatcher.actionTools.union(["batch"]) {
            let properties = tools[name]?.inputSchema["properties"] as? [String: [String: Any]]
            XCTAssertEqual(properties?["state"]?["enum"] as? [String], ["diff", "full", "none"], name)
            XCTAssertEqual(properties?["screenshot"]?["type"] as? String, "boolean", name)
            XCTAssertEqual(properties?["wait_for"]?["type"] as? String, "string", name)
            XCTAssertEqual(properties?["wait_timeout"]?["type"] as? String, "number", name)
        }
        for name in ["get_app_state", "list_apps", "query"] {
            let properties = tools[name]?.inputSchema["properties"] as? [String: Any]
            XCTAssertNil(properties?["state"], name)
        }
        let steps = (tools["batch"]?.inputSchema["properties"] as? [String: [String: Any]])?["steps"]
        let stepTool = ((steps?["items"] as? [String: Any])?["properties"] as? [String: [String: Any]])?["tool"]
        XCTAssertEqual(stepTool?["enum"] as? [String], ComputerUseToolDispatcher.actionTools.sorted())
    }
}
