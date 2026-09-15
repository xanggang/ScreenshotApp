import XCTest
@testable import ScreenshotApp

final class ScreenshotAppTests: XCTestCase {
    func testCompletionActionsRemainStableForPersistence() {
        XCTAssertEqual(CaptureCompletionAction.allCases.map(\.rawValue), ["copy", "save", "annotate", "pin"])
    }
}
