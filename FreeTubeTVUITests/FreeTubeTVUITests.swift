import XCTest

final class FreeTubeTVUITests: XCTestCase {
    func testLaunchShowsSearchEntryPoint() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.textFields["Search YouTube"].waitForExistence(timeout: 10))
    }
}
