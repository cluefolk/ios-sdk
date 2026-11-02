import XCTest

@testable import Cluefolk

/// The game's player ID is checked like the server checks claimedExternalId.
final class PlayerIdTests: XCTestCase {
  func testTrimmedAndBlankClears() {
    XCTAssertEqual(Cluefolk.normalizedPlayerId(nil), "")
    XCTAssertEqual(Cluefolk.normalizedPlayerId(""), "")
    XCTAssertEqual(Cluefolk.normalizedPlayerId(" \t\u{00A0}\u{3000} "), "")
    XCTAssertEqual(Cluefolk.normalizedPlayerId("  player-42 "), "player-42")
    XCTAssertEqual(Cluefolk.normalizedPlayerId("\r\nplayer 42\n"), "player 42")
  }

  func testLineBreaksAndNulInsideAreRejected() {
    XCTAssertNil(Cluefolk.normalizedPlayerId("a\nb"))
    XCTAssertNil(Cluefolk.normalizedPlayerId("a\rb"))
    XCTAssertNil(Cluefolk.normalizedPlayerId("a\r\nb"))
    XCTAssertNil(Cluefolk.normalizedPlayerId("a\0b"))
    XCTAssertNil(Cluefolk.normalizedPlayerId("ab\0"))
  }

  /// At most 256 characters after trimming, counted as Unicode code points like the server.
  func testLengthLimit() {
    XCTAssertEqual(Cluefolk.normalizedPlayerId(String(repeating: "a", count: 256))?.count, 256)
    XCTAssertNil(Cluefolk.normalizedPlayerId(String(repeating: "a", count: 257)))
    XCTAssertNotNil(Cluefolk.normalizedPlayerId("  " + String(repeating: "a", count: 256) + "  "))
    XCTAssertNotNil(Cluefolk.normalizedPlayerId(String(repeating: "😀", count: 256)))
    XCTAssertNil(Cluefolk.normalizedPlayerId(String(repeating: "😀", count: 257)))
    // "é" as e + combining accent: one character on screen, two code points.
    XCTAssertNotNil(Cluefolk.normalizedPlayerId(String(repeating: "e\u{301}", count: 128)))
    XCTAssertNil(Cluefolk.normalizedPlayerId(String(repeating: "e\u{301}", count: 129)))
  }
}
