import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchesWithStatusItem() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10) || app.state == .runningBackground)
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "menu bar status item is missing")
        app.terminate()
    }
}
