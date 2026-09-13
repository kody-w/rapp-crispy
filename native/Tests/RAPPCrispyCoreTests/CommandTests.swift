import Foundation
import XCTest
@testable import RAPPCrispyCore

final class CommandTests: XCTestCase {
    func testRecordingURLOnlyPreparesControls() throws {
        XCTAssertEqual(try NativeCommand.parse(URL(string: "rappcrispy://prepare-recording?name=Design%20review&seconds=60&screen=true")!),
                       .prepareRecording(name: "Design review", seconds: 60, requestScreen: true))
        XCTAssertEqual(try NativeCommand.parse(URL(string: "rappcrispy://history")!), .history)
    }

    func testUnknownAndUnsafeCommandsAreRejected() {
        for value in [
            "rappcrispy://record", "rappcrispy://stop", "rappcrispy://prepare-recording?notes=true",
            "rappcrispy://prepare-recording?seconds=-1", "rappcrispy://prepare-recording?screen=yes",
            "rappcrispy://prepare-recording?name=one&name=two", "rappcrispy://meeting?id=..%2Foutside",
            "https://history", "rappcrispy://diagnostics?run=sh", "rappcrispy://history/path"
        ] {
            XCTAssertThrowsError(try NativeCommand.parse(URL(string: value)!), value)
        }
    }
}
