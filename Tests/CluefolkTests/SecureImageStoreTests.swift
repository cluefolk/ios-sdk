import CryptoKit
import Security
import XCTest

@testable import Cluefolk

final class SecureImageStoreTests: XCTestCase {
  private var directory: URL!
  private let key = SymmetricKey(size: .bits256)

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("cluefolk-images-" + UUID().uuidString, isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func makeStore(key: SymmetricKey? = nil) -> SecureImageStore {
    let key = key ?? self.key
    return SecureImageStore(directory: directory, key: { key })
  }

  private func jpeg(_ seed: Int = 0, count: Int = 1_000) -> Data {
    Data([0xFF, 0xD8, 0xFF, 0xE0] + (0..<count).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
  }

  private func id(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", number) }

  private func file(_ namespace: String, _ id: String) -> URL {
    directory.appendingPathComponent(SecureImageStore.fileName(namespace: namespace, id: id))
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func testRoundTrip() async throws {
    let store = makeStore()
    let image = jpeg()
    try await store.write(namespace: "p/https://a/player", id: id(1), data: image)
    let read = try await store.read(namespace: "p/https://a/player", id: id(1))
    XCTAssertEqual(read, image)
    let missing = try await store.read(namespace: "p/https://a/player", id: id(2))
    XCTAssertNil(missing)

    let path = file("p/https://a/player", id(1))
    let expectedName = SHA256.hash(data: Data(("p/https://a/player/" + id(1)).utf8))
      .map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(path.lastPathComponent, expectedName)
    let sealed = try Data(contentsOf: path)
    XCTAssertEqual(sealed.count, image.count + 28)
    XCTAssertNil(sealed.range(of: image.prefix(64)), "the copy is stored in plaintext")
    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)

    // Writing the same ID again replaces the copy.
    try await store.write(namespace: "p/https://a/player", id: id(1), data: jpeg(7))
    let replaced = try await store.read(namespace: "p/https://a/player", id: id(1))
    XCTAssertEqual(replaced, jpeg(7))
  }

  func testOtherAccountCannotRead() async throws {
    let store = makeStore()
    try await store.write(namespace: "p/https://a/alice", id: id(1), data: jpeg())
    let other = try await store.read(namespace: "p/https://a/bob", id: id(1))
    XCTAssertNil(other)

    // A copy moved under another account or ID fails authentication and is deleted.
    for (namespace, target) in [("p/https://a/bob", id(1)), ("p/https://a/alice", id(2))] {
      let moved = file(namespace, target)
      try FileManager.default.copyItem(at: file("p/https://a/alice", id(1)), to: moved)
      let read = try await store.read(namespace: namespace, id: target)
      XCTAssertNil(read)
      XCTAssertFalse(exists(moved))
    }
    let original = try await store.read(namespace: "p/https://a/alice", id: id(1))
    XCTAssertEqual(original, jpeg())
  }

  func testCorruptCopyIsRemoved() async throws {
    let store = makeStore()
    let path = file("ns", id(1))
    var corruptions: [(Data) -> Data] = [{ _ in Data([1, 2, 3]) }, { Data($0.dropLast()) }]
    corruptions.append { sealed in
      var flipped = sealed
      flipped[20] ^= 0x01
      return flipped
    }
    for corrupt in corruptions {
      try await store.write(namespace: "ns", id: id(1), data: jpeg())
      try corrupt(try Data(contentsOf: path)).write(to: path)
      let read = try await store.read(namespace: "ns", id: id(1))
      XCTAssertNil(read)
      XCTAssertFalse(exists(path))
    }

    // A copy sealed under another key (a replaced Keychain key) is deleted too.
    try await store.write(namespace: "ns", id: id(1), data: jpeg())
    let rekeyed = try await makeStore(key: SymmetricKey(size: .bits256)).read(namespace: "ns", id: id(1))
    XCTAssertNil(rekeyed)
    XCTAssertFalse(exists(path))
  }

  func testKeyFailureKeepsTheCopy() async throws {
    try await makeStore().write(namespace: "ns", id: id(1), data: jpeg())
    let locked = SecureImageStore(directory: directory, key: { throw CluefolkError.invalidResponse })
    do {
      _ = try await locked.read(namespace: "ns", id: id(1))
      XCTFail("an unavailable key must be an error, not a missing copy")
    } catch {}
    XCTAssertTrue(exists(file("ns", id(1))))
    do {
      try await locked.write(namespace: "ns", id: id(2), data: jpeg())
      XCTFail("an unavailable key must fail the write")
    } catch {}
    let missing = try await locked.read(namespace: "ns", id: id(3))
    XCTAssertNil(missing)
  }

  func testRejectsOtherContent() async throws {
    let store = makeStore()
    for data in [Data([0x89, 0x50, 0x4E, 0x47, 0, 0]), Data(), jpeg(count: 90_000 - 3)] {
      do {
        try await store.write(namespace: "ns", id: id(1), data: data)
        XCTFail("stored \(data.count) bytes")
      } catch {}
    }
    try await store.write(namespace: "ns", id: id(1), data: jpeg(count: 90_000 - 4))
    let largest = try await store.read(namespace: "ns", id: id(1))
    XCTAssertEqual(largest?.count, 90_000)
  }

  func testKeepsTheNewest200() async throws {
    let store = makeStore()
    for number in 0..<200 { try await store.write(namespace: "ns", id: id(number), data: jpeg(number)) }
    // Distinct, known ages: copy 0 is the oldest.
    let start = Date().addingTimeInterval(-3_600)
    for number in 0..<200 {
      try FileManager.default.setAttributes(
        [.modificationDate: start.addingTimeInterval(Double(number))], ofItemAtPath: file("ns", id(number)).path)
    }
    try await store.write(namespace: "ns", id: id(200), data: jpeg(200))
    var names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names.count, 200)
    XCTAssertFalse(exists(file("ns", id(0))))
    let oldest = try await store.read(namespace: "ns", id: id(0))
    XCTAssertNil(oldest)
    for number in [1, 199, 200] {
      let kept = try await store.read(namespace: "ns", id: id(number))
      XCTAssertEqual(kept, jpeg(number), "copy \(number)")
    }

    try await store.write(namespace: "other", id: id(1), data: jpeg())
    names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names.count, 200)
    XCTAssertFalse(exists(file("ns", id(1))))
    XCTAssertTrue(exists(file("other", id(1))))
  }

  func testClear() async throws {
    let store = makeStore()
    try await store.write(namespace: "a", id: id(1), data: jpeg())
    try await store.write(namespace: "b", id: id(2), data: jpeg())
    try await store.clear()
    let first = try await store.read(namespace: "a", id: id(1))
    let second = try await store.read(namespace: "b", id: id(2))
    XCTAssertNil(first)
    XCTAssertNil(second)
    XCTAssertFalse(exists(directory))
    try await store.clear()
    try await store.write(namespace: "a", id: id(1), data: jpeg())
    let again = try await store.read(namespace: "a", id: id(1))
    XCTAssertEqual(again, jpeg())
    XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  /// The real key: created on first use, then the same key.
  func testKeychainKeyIsStable() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.cluefolk.images",
      kSecAttrAccount as String: "aes-gcm-key",
    ]
    SecItemDelete(query as CFDictionary)
    defer { SecItemDelete(query as CFDictionary) }
    let first: SymmetricKey
    do { first = try SecureImageStore.keychainKey() } catch {
      var probe = query
      probe[kSecReturnData as String] = true
      throw XCTSkip("Keychain is unavailable here (OSStatus \(SecItemCopyMatching(probe as CFDictionary, nil)))")
    }
    let second = try SecureImageStore.keychainKey()
    XCTAssertEqual(first.bitCount, 256)
    XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
  }

  func testBridgeValidatesImageRequests() {
    XCTAssertTrue(Cluefolk.isImageId("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"))
    for bad in ["0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D", "0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d", "new",
      "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d\n", "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4g", ""] {
      XCTAssertFalse(Cluefolk.isImageId(bad), bad)
    }

    let image = jpeg(count: 996)  // 1,000 bytes: base64 ends with "=="
    let padded = image.base64EncodedString()
    XCTAssertTrue(padded.hasSuffix("=="))
    XCTAssertEqual(Cluefolk.decodeImage(padded), image)
    XCTAssertEqual(Cluefolk.decodeImage(String(padded.dropLast(2))), image)
    let largest = jpeg(count: 90_000 - 4)
    XCTAssertEqual(largest.base64EncodedString().count, 120_000)
    XCTAssertEqual(Cluefolk.decodeImage(largest.base64EncodedString()), largest)

    let urlSafe = Data([0xFF, 0xD8, 0xFF, 0xFB, 0xEF, 0xFF]).base64EncodedString()
    XCTAssertTrue(urlSafe.contains("+") || urlSafe.contains("/"))
    XCTAssertNotNil(Cluefolk.decodeImage(urlSafe))
    let rejected: [Any?] = [
      nil, 42, "", "====", padded + "=", " " + padded, padded.replacingOccurrences(of: "=", with: "") + "\n",
      urlSafe.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"),
      Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(), jpeg(count: 90_000 - 3).base64EncodedString(),
      String(padded.dropLast(3)),
    ]
    for value in rejected { XCTAssertNil(Cluefolk.decodeImage(value), String(describing: value)) }
  }
}
