import XCTest

@testable import Cluefolk

final class OriginTests: XCTestCase {
  @MainActor func testOriginsAreExact() {
    XCTAssertEqual(
      Cluefolk.origin(URL(string: "https://support.example:8443/widget")!),
      "https://support.example:8443")
    XCTAssertFalse(Cluefolk.trusted(URL(string: "https://user:pass@support.example")!))
    XCTAssertFalse(Cluefolk.trusted(URL(string: "file:///tmp/widget.html")!))
    XCTAssertFalse(Cluefolk.trusted(URL(string: "http://support.example")!))
    XCTAssertFalse(Cluefolk.trusted(URL(string: "https://support.example?token=secret")!))
  }
}
