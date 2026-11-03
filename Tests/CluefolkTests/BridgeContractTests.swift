import XCTest

@testable import Cluefolk

final class BridgeContractTests: XCTestCase {
  private func envelope(_ name: String) throws -> [String: Any] {
    let text = try XCTUnwrap(BridgeFixtures.all[name], name)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], name)
  }

  @MainActor func testFixturesMatchProtocol() throws {
    let replies: Set = [BridgeProtocol.sdkBootstrap, BridgeProtocol.sdkAck, BridgeProtocol.sdkError]
    XCTAssertFalse(BridgeFixtures.all.isEmpty)
    for name in BridgeFixtures.all.keys.sorted() {
      let value = try envelope(name)
      let type = try XCTUnwrap(value["type"] as? String, name)
      XCTAssertEqual(name, type + ".json")
      XCTAssertEqual(value["protocol"] as? String, BridgeProtocol.protocolName, name)
      XCTAssertEqual(value["version"] as? Int, BridgeProtocol.version, name)
      XCTAssertTrue(BridgeProtocol.nativeRequests.contains(type) || replies.contains(type), name)
      if type.hasPrefix("native.") {
        XCTAssertTrue(BridgeProtocol.nativeRequests.contains(type), name)
        XCTAssertEqual(Cluefolk.bridgeRequest(value)?.type, type, name)
      } else {
        XCTAssertNil(Cluefolk.bridgeRequest(value), name)
      }
    }
    for type in BridgeProtocol.nativeRequests { XCTAssertNotNil(BridgeFixtures.all[type + ".json"], type) }
  }

  @MainActor func testRejectsOtherVersionsAndCommands() throws {
    var value = try envelope("native.ready.json")
    value["version"] = 1
    XCTAssertNil(Cluefolk.bridgeRequest(value))
    value["version"] = BridgeProtocol.version
    value["type"] = "native.renew"
    XCTAssertNil(Cluefolk.bridgeRequest(value))
  }

  @MainActor func testRejectsMalformedAndExtraNativePayloadFields() throws {
    func rejected(_ name: String, _ payload: [String: Any]) throws {
      var value = try envelope(name + ".json")
      value["payload"] = payload
      XCTAssertNil(Cluefolk.bridgeRequest(value), name)
    }
    try rejected("native.ready", ["extra": true])
    try rejected("native.unreadCountChanged", ["count": -1])
    try rejected("native.unreadCountChanged", ["count": "1"])
    try rejected("native.unreadCountChanged", ["count": true])
    try rejected("native.historyPage", ["syncId": "sync", "index": 0, "extra": true])
    try rejected("native.historyPage", ["syncId": "sync", "index": false])
    try rejected("native.conversationStatusChanged", ["conversationId": "conversation", "status": "unknown"])
    try rejected("native.draftPut", ["key": "new", "content": "not-an-object"])
    try rejected("native.imageGet", ["id": "0b6a9c3e-7d1f-4e2a-9c58-3f0e2d1b4a77", "extra": true])
  }

  @MainActor func testDraftFixtureFitsWhitelist() throws {
    let payload = try XCTUnwrap(envelope("native.draftPut.json")["payload"] as? [String: Any])
    let content = try XCTUnwrap(payload["content"] as? [String: Any])
    XCTAssertTrue(Set(content.keys).isSubset(of: Cluefolk.draftFields))
    XCTAssertFalse(Cluefolk.draftFields.contains("subject"))
  }

  func testImageFixturesPassValidation() throws {
    let put = try XCTUnwrap(envelope("native.imagePut.json")["payload"] as? [String: Any])
    XCTAssertEqual(Set(put.keys), ["id", "data"])
    XCTAssertTrue(Cluefolk.isImageId(try XCTUnwrap(put["id"] as? String)))
    XCTAssertNotNil(Cluefolk.decodeImage(put["data"]))
    let get = try XCTUnwrap(envelope("native.imageGet.json")["payload"] as? [String: Any])
    XCTAssertEqual(Set(get.keys), ["id"])
    XCTAssertTrue(Cluefolk.isImageId(try XCTUnwrap(get["id"] as? String)))
  }

  @MainActor func testBootstrapPayloadMatchesContract() throws {
    let fixture = try XCTUnwrap(envelope("sdk.bootstrap.json")["payload"] as? [String: Any])
    let fixturePlayer = try XCTUnwrap(fixture["player"] as? [String: Any])
    let sdk = Cluefolk()
    let anonymous = StoredSession(
      token: "t", expiresAt: Date(), playerId: "p", kind: "anonymous", externalUserId: nil, claimedExternalId: "")
    var payload = sdk.bootstrapPayload(
      code: String(repeating: "Z", count: 43), apiURL: URL(string: "https://cluefolk.example/api")!, session: anonymous)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    XCTAssertTrue(Set(payload.keys).isSubset(of: fixture.keys))
    for key in ["code", "apiBaseUrl", "context", "player"] { XCTAssertNotNil(payload[key], key) }
    XCTAssertEqual(payload["apiBaseUrl"] as? String, "https://cluefolk.example")
    XCTAssertNotNil((payload["context"] as? [String: Any])?["_cluefolk"])
    let navigation = try XCTUnwrap(payload["navigation"] as? [String: String])
    XCTAssertTrue(BridgeProtocol.navigationScreens.contains(navigation["screen"] ?? ""))
    XCTAssertNotNil(navigation["id"])
    var player = try XCTUnwrap(payload["player"] as? [String: Any])
    XCTAssertEqual(Set(player.keys), Set(fixturePlayer.keys))
    XCTAssertEqual(player["kind"] as? String, "anonymous")
    XCTAssertTrue(player["externalUserId"] is NSNull)

    let verified = StoredSession(
      token: "t", expiresAt: Date(), playerId: "p", kind: "verified", externalUserId: "alice", claimedExternalId: "")
    payload = sdk.bootstrapPayload(code: String(repeating: "Z", count: 43), apiURL: URL(string: "https://cluefolk.example")!, session: verified)
    player = try XCTUnwrap(payload["player"] as? [String: Any])
    XCTAssertEqual(player["externalUserId"] as? String, "alice")
  }

  func testInstallSecretFormat() throws {
    let secret = try XCTUnwrap(Cluefolk.makeInstallSecret())
    XCTAssertEqual(secret.count, 43)
    let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    XCTAssertNil(secret.rangeOfCharacter(from: alphabet.inverted))
    let standard = secret.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
    XCTAssertEqual(Data(base64Encoded: standard)?.count, 32)
    XCTAssertNotEqual(secret, Cluefolk.makeInstallSecret())
  }
}
