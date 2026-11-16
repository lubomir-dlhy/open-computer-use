@testable import OpenComputerUseKit
import XCTest

final class BrowserToolTests: XCTestCase {
    func testDiffReportsChangedAddedAndRemovedLinesByRef() {
        let before = ["[1] heading \"todos\" h1", "[2] textbox \"New\" focused", "3 items left!"]
        let after = ["[1] heading \"todos\" h1", "[2] textbox \"New\" value=\"x\" focused", "[4] button \"Clear\"", "2 items left!"]
        XCTAssertEqual(BrowserTool.diff(before: before, after: after), [
            "~ [2] textbox \"New\" value=\"x\" focused",
            "+ [4] button \"Clear\"",
            "+ 2 items left!",
            "- 3 items left!",
        ])
        XCTAssertEqual(BrowserTool.diff(before: after, after: after), [])
    }

    func testDiffIsCappedWithAPointerToASnapshot() {
        let after = (1...60).map { "[\($0)] link \"\($0)\"" }
        let changes = BrowserTool.diff(before: [], after: after, limit: 10)
        XCTAssertEqual(changes.count, 11)
        XCTAssertEqual(changes.last, "… 50 more changes; take a snapshot")
    }

    func testBrowserToolRejectsUnknownActions() {
        XCTAssertThrowsError(try BrowserTool().call(["action": "teleport"]))
        XCTAssertThrowsError(try BrowserTool().call(["action": "click"]), "no current tab")
    }

    func testProfilesMatchByNameEmailOrDirectoryButNotByNote() {
        let personal = BrowserProfile(directory: "Profile 17", name: "Ľubomír", email: "me@gmail.com", note: "personal; not CulturePulse")
        let work = BrowserProfile(directory: "Profile 16", name: "culturepulse.ai", email: "me@culturepulse.ai")
        let contact = BrowserProfile(directory: "Profile 20", name: "contact@lubomirdlhy.sk", email: "")
        let profiles = [personal, work, contact]
        XCTAssertEqual(BrowserProfiles.select("culturepulse", from: profiles), work)
        XCTAssertEqual(BrowserProfiles.select("me@gmail.com", from: profiles), personal)
        XCTAssertEqual(BrowserProfiles.select("Profile 20", from: profiles), contact)
        XCTAssertEqual(BrowserProfiles.select("lubomirdlhy.sk", from: profiles), contact)
        XCTAssertNil(BrowserProfiles.select("culturepulse", from: [personal]))
        XCTAssertNil(BrowserProfiles.select("me@", from: profiles), "ambiguous")
    }

    func testNativeHostIsRecognisedFromChromesLaunchArgument() {
        XCTAssertTrue(BrowserNativeHost.isInvocation(arguments: ["chrome-extension://\(BrowserNativeHost.extensionID)/"]))
        XCTAssertTrue(BrowserNativeHost.isInvocation(arguments: ["browser-host"]))
        XCTAssertFalse(BrowserNativeHost.isInvocation(arguments: ["mcp"]))
    }

    func testFramesRoundTripThroughASocketPair() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let payload = Data(#"{"id":1,"method":"getInfo"}"#.utf8)
        XCTAssertTrue(BrowserSocket.writeFrame(fd: fds[0], payload))
        XCTAssertEqual(BrowserSocket.readFrame(fd: fds[1]), payload)
    }

    func testMarkdownBecomesHTMLForRichPaste() {
        XCTAssertEqual(
            PasteContent.html(fromMarkdown: "# Title\n\nSome **bold** and *it* with `code` and [a link](https://x.test).\n\n- one\n- two\n\n1. first"),
            "<h1>Title</h1><p>Some <strong>bold</strong> and <em>it</em> with <code>code</code> and <a href=\"https://x.test\">a link</a>.</p><ul><li>one</li><li>two</li></ul><ol><li>first</li></ol>"
        )
        XCTAssertEqual(PasteContent.html(fromMarkdown: "a < b & c"), "<p>a &lt; b &amp; c</p>")
    }

    func testPasteNeverTakesASecret() {
        XCTAssertThrowsError(try ComputerUseToolDispatcher().callTool(
            name: "type_text", arguments: ["app": "missing-test-app", "paste": true, "secret_env": "X_PASSWORD"])) {
            XCTAssertTrue("\($0)".contains("cannot be pasted"))
        }
    }

    func testHoldIsBounded() {
        XCTAssertThrowsError(try ComputerUseToolDispatcher().callTool(
            name: "press_key", arguments: ["app": "missing-test-app", "key": "a", "hold": 30]))
    }

    func testProductSummariesCoverCommonShopShapes() {
        let jsonld: [[String: Any]] = [
            ["@type": "Product", "name": "Kettle", "gtin13": "4006381333931", "brand": ["@type": "Brand", "name": "Bosch"],
             "offers": ["@type": "AggregateOffer", "lowPrice": 39, "highPrice": "54.90", "priceCurrency": "EUR",
                        "availability": "https://schema.org/InStock"]],
            ["@type": "ProductGroup", "name": "Tee", "hasVariant": [
                ["@type": "Product", "name": "Tee S", "sku": "T-S",
                 "offers": [["price": "19.00", "priceCurrency": "EUR", "availability": "http://schema.org/OutOfStock", "seller": ["name": "Shop A"]],
                            ["price": "21.00", "priceCurrency": "EUR", "availability": "InStock"]]],
            ]],
            ["@type": "BreadcrumbList"],
        ]
        XCTAssertEqual(BrowserTool.productSummaries(jsonld: jsonld, microdata: [], meta: [:]), [
            "Product \"Kettle\", 39–54.90 EUR (InStock), gtin13 4006381333931, brand Bosch",
            "Product \"Tee\"",
            "Product \"Tee S\", 19.00 EUR (OutOfStock) seller Shop A; 21.00 EUR (InStock), sku T-S",
        ])
        XCTAssertEqual(BrowserTool.productSummaries(jsonld: [], microdata: [
            ["name": "Lamp", "price": "12.50", "priceCurrency": "USD", "availability": "https://schema.org/LimitedAvailability", "sku": "L1"],
        ], meta: [:]), ["Product \"Lamp\", 12.50 USD (LimitedAvailability), sku L1"])
        XCTAssertEqual(BrowserTool.productSummaries(jsonld: [], microdata: [], meta: [
            "og:title": "Chair", "product:price:amount": "99", "product:price:currency": "CZK", "product:availability": "in stock",
        ]), ["Product \"Chair\", 99 CZK (in stock)"])
        XCTAssertEqual(BrowserTool.productSummaries(jsonld: [["@type": "WebPage"]], microdata: [], meta: [:]), [])
    }

    func testClipSaysHowMuchWasLeftOut() {
        XCTAssertEqual(BrowserTool.clip("abcdef", 4, hint: "raise max_chars"), "abcd… (2 more chars; raise max_chars)")
        XCTAssertEqual(BrowserTool.clip("abc", 4, hint: "x"), "abc")
    }
}
