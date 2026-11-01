@testable import OpenComputerUseKit
import CoreGraphics
import XCTest

final class CursorCoverTests: XCTestCase {
    private func window(_ id: Int, pid: Int, _ rect: CGRect, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary]
    }

    func testCursorStaysHiddenOverTheUsersApp() {
        let user = window(1, pid: 100, CGRect(x: 0, y: 0, width: 800, height: 600))
        let target = window(2, pid: 200, CGRect(x: 100, y: 100, width: 800, height: 600))
        // Target behind the user's window: the panel sits below the user's window.
        XCTAssertFalse(cursorPanelWouldCoverFrontmostApp(targetWindowID: 2, frontmostPID: 100, ownPID: 1, windows: [user, target]))
        // Target in front of an overlapping user window: the panel would land above it.
        XCTAssertTrue(cursorPanelWouldCoverFrontmostApp(targetWindowID: 2, frontmostPID: 100, ownPID: 1, windows: [target, user]))
        // The target is itself a window of the app the user is in.
        let sameApp = window(3, pid: 100, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(cursorPanelWouldCoverFrontmostApp(targetWindowID: 3, frontmostPID: 100, ownPID: 1, windows: [sameApp, user]))
        // A user window elsewhere on screen is not covered.
        let far = window(4, pid: 100, CGRect(x: 2000, y: 0, width: 300, height: 300))
        XCTAssertFalse(cursorPanelWouldCoverFrontmostApp(targetWindowID: 2, frontmostPID: 100, ownPID: 1, windows: [target, far]))
    }
}
