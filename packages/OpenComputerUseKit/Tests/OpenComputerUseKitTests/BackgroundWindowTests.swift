@testable import OpenComputerUseKit
import XCTest

final class BackgroundWindowTests: XCTestCase {
    func testMenuTitlesMatchCaseInsensitivelyAndByUniquePrefix() {
        let titles = ["New tab", "New window", "New Incognito window", "Open File…", "Compress “beach.jpg”"]
        XCTAssertEqual(MenuPath.match("new WINDOW", in: titles), 1)
        XCTAssertEqual(MenuPath.match("Open File...", in: titles), 3)
        XCTAssertEqual(MenuPath.match("Compress", in: titles), 4)
        XCTAssertNil(MenuPath.match("New", in: titles), "ambiguous prefixes fail")
        XCTAssertNil(MenuPath.match("Print", in: titles))
    }

    func testPinFollowsOnlyNewWindows() {
        let pin = WindowPin(windowID: 10, knownWindowIDs: [10, 11])
        XCTAssertFalse(pin.followsFocus(to: 11), "the user's other window does not move the agent")
        XCTAssertTrue(pin.followsFocus(to: 12), "a window the agent just opened is followed")
        XCTAssertFalse(pin.followsFocus(to: nil))
        XCTAssertFalse(WindowPin(windowID: 10, knownWindowIDs: [], explicit: true).followsFocus(to: 12))
    }

    func testClickMenuPathRejectsMixedTargets() {
        let dispatcher = ComputerUseToolDispatcher()
        XCTAssertThrowsError(try dispatcher.callTool(name: "click", arguments: ["app": "missing-test-app", "menu_path": ["File"], "element_index": "1"]))
        XCTAssertThrowsError(try dispatcher.callTool(name: "click", arguments: ["app": "missing-test-app", "menu_path": "File"]))
    }
}
