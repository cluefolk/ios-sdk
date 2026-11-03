import XCTest

@testable import Cluefolk

final class NetworkBoundsTests: XCTestCase {
  private func stream(_ values: [UInt8]) -> AsyncStream<UInt8> {
    AsyncStream { (continuation: AsyncStream<UInt8>.Continuation) in
      for value in values { continuation.yield(value) }
      continuation.finish()
    }
  }

  func testResponseBodyLimitIsInclusiveAndRejectsTheNextByte() async throws {
    let accepted = try await Cluefolk.boundedResponseData(stream([1, 2, 3, 4]), limit: 4)
    XCTAssertEqual(accepted, Data([1, 2, 3, 4]))
    do {
      _ = try await Cluefolk.boundedResponseData(stream([1, 2, 3, 4, 5]), limit: 4)
      XCTFail("An over-limit response was accepted")
    } catch CluefolkError.invalidResponse {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testHistoryPageAndCursorLimits() throws {
    func page(_ next: String) -> [String: Any] {
      ["conversations": [["id": "conversation"]], "messages": [["id": "message"]], "nextCursor": next]
    }
    var cursors: Set<String> = []
    XCTAssertEqual(try Cluefolk.historyNextCursor(page("next"), pageCount: 0, cursors: &cursors), "next")
    XCTAssertEqual(try Cluefolk.historyNextCursor(page(""), pageCount: Cluefolk.maxHistoryPages - 1, cursors: &cursors), "")
    XCTAssertThrowsError(try Cluefolk.historyNextCursor(page("last"), pageCount: Cluefolk.maxHistoryPages, cursors: &cursors))
    XCTAssertThrowsError(try Cluefolk.historyNextCursor(page("next"), pageCount: 1, cursors: &cursors))
    XCTAssertThrowsError(try Cluefolk.historyNextCursor(page(String(repeating: "x", count: 1025)), pageCount: 1, cursors: &cursors))
    XCTAssertThrowsError(try Cluefolk.historyNextCursor(
      ["conversations": [], "messages": "not-an-array", "nextCursor": ""], pageCount: 0, cursors: &cursors))
  }
}
