import XCTest
import AppKit
@testable import TechMarkdown

final class ApplicationIconTests: XCTestCase {
    func testApplicationIconCanBeLoadedFromBuiltAppBundle() throws {
        let icon = try XCTUnwrap(ApplicationIconProvider.load())
        XCTAssertFalse(icon.isTemplate)
        XCTAssertGreaterThan(icon.size.width, 0)
        XCTAssertGreaterThan(icon.size.height, 0)
    }
}
