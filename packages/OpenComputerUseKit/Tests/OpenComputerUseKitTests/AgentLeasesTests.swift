@testable import OpenComputerUseKit
import XCTest

final class AgentLeasesTests: XCTestCase {
    private let chromeA = LeasedResource.window(pid: 10, windowID: 1)
    private let chromeB = LeasedResource.window(pid: 10, windowID: 2)
    private let settings = LeasedResource.app(pid: 20)

    func testConflictsAreScopedToTheSameWindowOrApp() {
        XCTAssertFalse(chromeA.conflicts(with: chromeB))
        XCTAssertTrue(chromeA.conflicts(with: chromeA))
        XCTAssertTrue(LeasedResource.app(pid: 10).conflicts(with: chromeA))
        XCTAssertFalse(settings.conflicts(with: chromeA))
    }

    func testOtherSessionsWaitThenFailWhileTheirOwnWindowsStayFree() throws {
        let leases = AgentLeases()
        try leases.perform(chromeA, session: 1, wait: 0, idleExpiry: 60) {}
        XCTAssertThrowsError(try leases.perform(chromeA, session: 2, wait: 0.1, idleExpiry: 60) {}) {
            XCTAssertEqual(($0 as? LeaseBusy)?.owner, 1)
        }
        XCTAssertNoThrow(try leases.perform(chromeB, session: 2, wait: 0, idleExpiry: 60) {})
        XCTAssertNoThrow(try leases.perform(chromeA, session: 1, wait: 0, idleExpiry: 60) {}, "the owner keeps its window")
        XCTAssertEqual(leases.otherOwner(of: chromeA, session: 2, idleExpiry: 60), 1)
        XCTAssertNil(leases.otherOwner(of: chromeA, session: 1, idleExpiry: 60))
    }

    func testSingletonAppsAreOneSessionAtATime() throws {
        let leases = AgentLeases()
        try leases.perform(settings, session: 1, wait: 0, idleExpiry: 60) {}
        XCTAssertThrowsError(try leases.perform(settings, session: 2, wait: 0.05, idleExpiry: 60) {})
        leases.release(session: 1)
        XCTAssertNoThrow(try leases.perform(settings, session: 2, wait: 0, idleExpiry: 60) {})
    }

    func testIdleClaimsExpire() throws {
        var clock = Date(timeIntervalSince1970: 0)
        let leases = AgentLeases(now: { clock })
        try leases.perform(settings, session: 1, wait: 0, idleExpiry: 120) {}
        clock = clock.addingTimeInterval(121)
        XCTAssertNoThrow(try leases.perform(settings, session: 2, wait: 0, idleExpiry: 120) {})
    }

    func testMovingToAnotherWindowFreesTheLastOne() throws {
        let leases = AgentLeases()
        try leases.perform(chromeA, session: 1, wait: 0, idleExpiry: 60) {}
        try leases.perform(chromeB, session: 1, wait: 0, idleExpiry: 60) {}
        XCTAssertNoThrow(try leases.perform(chromeA, session: 2, wait: 0, idleExpiry: 60) {})
    }

    func testWaitersProceedWhenTheHolderFinishes() throws {
        let leases = AgentLeases()
        let started = expectation(description: "holder running")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? leases.perform(self.chromeA, session: 1, wait: 0, idleExpiry: 60) {
                started.fulfill()
                release.wait()
            }
            leases.release(session: 1)
        }
        wait(for: [started], timeout: 2)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
        let begin = Date()
        XCTAssertNoThrow(try leases.perform(chromeA, session: 2, wait: 3, idleExpiry: 60) {})
        XCTAssertGreaterThan(Date().timeIntervalSince(begin), 0.1)
    }

    func testInputToOneProcessIsSerializedEvenAcrossWindows() throws {
        let leases = AgentLeases()
        let inside = expectation(description: "first call inside")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? leases.perform(self.chromeA, session: 1, wait: 0, idleExpiry: 60) {
                inside.fulfill()
                release.wait()
            }
        }
        wait(for: [inside], timeout: 2)
        XCTAssertThrowsError(try leases.perform(chromeB, session: 2, wait: 0.05, idleExpiry: 60) {})
        release.signal()
        XCTAssertNoThrow(try leases.perform(chromeB, session: 2, wait: 2, idleExpiry: 60) {})
    }

    func testAppsThatOpenWindowsAreSharedByWindow() {
        XCTAssertTrue(AppConcurrency.opensWindows(menuTitles: ["New tab", "New window", "Open File…"]))
        XCTAssertTrue(AppConcurrency.opensWindows(menuTitles: ["New Finder Window", "New Folder"]))
        XCTAssertTrue(AppConcurrency.opensWindows(menuTitles: ["New", "Open…"]), "TextEdit")
        XCTAssertFalse(AppConcurrency.opensWindows(menuTitles: ["New Note", "New Folder", "Close"]), "Notes")
        XCTAssertFalse(AppConcurrency.opensWindows(menuTitles: ["About System Settings", "Quit"]))
        let env = ["OPEN_COMPUTER_USE_SINGLETON_APPS": "com.google.Chrome"]
        XCTAssertTrue(AppConcurrency.isSingleton(bundleIdentifier: "com.google.Chrome", name: "Google Chrome", environment: env) { ["New window"] })
    }

    func testRequestEnvironmentIsPerThread() {
        let done = expectation(description: "other thread")
        RequestEnvironment.with(["OPEN_COMPUTER_USE_X": "a"]) {
            DispatchQueue.global().async {
                XCTAssertNil(RequestEnvironment.current["OPEN_COMPUTER_USE_X"])
                done.fulfill()
            }
            XCTAssertEqual(RequestEnvironment.current["OPEN_COMPUTER_USE_X"], "a")
            wait(for: [done], timeout: 2)
        }
        XCTAssertNil(RequestEnvironment.current["OPEN_COMPUTER_USE_X"])
    }
}
