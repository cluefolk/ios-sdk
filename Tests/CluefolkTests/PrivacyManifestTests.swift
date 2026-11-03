import XCTest

final class PrivacyManifestTests: XCTestCase {
  func testPrivacyManifestMatchesTheSDKDataFlowAndRequiredReasons() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("Sources/CluefolkPrivacy/PrivacyInfo.xcprivacy")
    let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    let manifest = try XCTUnwrap(value as? [String: Any])
    XCTAssertEqual(Set(manifest.keys), ["NSPrivacyTracking", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"])
    XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    XCTAssertEqual(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }), [
      "NSPrivacyCollectedDataTypeCustomerSupport", "NSPrivacyCollectedDataTypePhotosorVideos",
      "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID",
      "NSPrivacyCollectedDataTypeOtherDataTypes",
    ])
    for entry in collected {
      XCTAssertEqual(Set(entry.keys), [
        "NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeLinked",
        "NSPrivacyCollectedDataTypeTracking", "NSPrivacyCollectedDataTypePurposes",
      ])
      XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
      XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
      XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], [
        "NSPrivacyCollectedDataTypePurposeAppFunctionality",
      ])
    }
    let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    let reasons = Dictionary(uniqueKeysWithValues: try entries.map { entry in
      let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
      let values = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
      return (category, values)
    })
    XCTAssertEqual(reasons, [
      "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
      "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
    ])
  }
}
