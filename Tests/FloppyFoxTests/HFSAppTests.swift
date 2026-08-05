#if canImport(XCTest)
import XCTest
@testable import FloppyFox

final class FloppyFoxTests: XCTestCase {
    func testExample() throws {
        XCTAssertTrue(true)
    }
}
#else
// XCTest is unavailable in this Swift toolchain, so this test target is disabled.
#endif
