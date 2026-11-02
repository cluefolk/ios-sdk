import CryptoKit
import Foundation
import Security

/// The player's own copies of images they sent. The server never returns images to
/// players, so after an upload the widget hands native code a small JPEG preview
/// (native.imagePut) and asks for it again to show chat history (native.imageGet).
///
/// Each copy is a file in Application Support/Cluefolk/Images (excluded from backup)
/// sealed with AES-GCM under a Keychain key that never leaves this device. The file
/// name and the authenticated data are bound to the account namespace and the image
/// ID, so a copy cannot be read under another account or ID. File I/O is serialized
/// here, off the main actor; the newest 200 copies are kept.
actor SecureImageStore {
  static let shared = SecureImageStore(directory: defaultDirectory, key: { try keychainKey() })
  static let limit = 200
  static let maxBytes = 90_000
  /// Nonce and tag around the ciphertext in the combined representation.
  private static let overhead = 12 + 16
  private let directory: URL?
  private let keySource: @Sendable () throws -> SymmetricKey
  private var cachedKey: SymmetricKey?

  init(directory: URL?, key: @escaping @Sendable () throws -> SymmetricKey) {
    self.directory = directory
    keySource = key
  }

  static var defaultDirectory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Cluefolk/Images", isDirectory: true)
  }

  static func isJPEG(_ data: Data) -> Bool {
    data.count <= maxBytes && data.starts(with: [0xFF, 0xD8, 0xFF])
  }

  /// SHA-256 hex of the binding, which is also the AES-GCM authenticated data.
  static func fileName(namespace: String, id: String) -> String {
    SHA256.hash(data: Data(binding(namespace: namespace, id: id).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func binding(namespace: String, id: String) -> String { namespace + "/" + id }

  func write(namespace: String, id: String, data: Data) throws {
    guard let directory, Self.isJPEG(data) else { throw CluefolkError.invalidResponse }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var folder = directory
    try folder.setResourceValues(excluded)
    let binding = Data(Self.binding(namespace: namespace, id: id).utf8)
    guard let sealed = try AES.GCM.seal(data, using: key(), authenticating: binding).combined
    else { throw CluefolkError.invalidResponse }
    let name = Self.fileName(namespace: namespace, id: id)
    try sealed.write(
      to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try prune(keeping: name)
  }

  /// nil when there is no copy; a copy that fails to open is deleted.
  func read(namespace: String, id: String) throws -> Data? {
    guard let directory else { throw CluefolkError.invalidResponse }
    let file = directory.appendingPathComponent(Self.fileName(namespace: namespace, id: id))
    let sealed: Data
    do {
      sealed = try Data(contentsOf: file)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
    let key = try key()
    let binding = Data(Self.binding(namespace: namespace, id: id).utf8)
    guard sealed.count <= Self.maxBytes + Self.overhead,
      let box = try? AES.GCM.SealedBox(combined: sealed),
      let data = try? AES.GCM.open(box, using: key, authenticating: binding), Self.isJPEG(data)
    else {
      try remove(file)
      return nil
    }
    return data
  }

  /// Deletes every copy. The key stays in the Keychain; without the files it opens nothing.
  func clear() throws {
    guard let directory else { return }
    try remove(directory)
  }

  private func key() throws -> SymmetricKey {
    if let cachedKey { return cachedKey }
    let key = try keySource()
    cachedKey = key
    return key
  }

  /// Keeps the newest copies by modification date; the one just written always stays.
  private func prune(keeping current: String) throws {
    guard let directory else { return }
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    guard files.count > Self.limit else { return }
    let others = try files.filter { $0.lastPathComponent != current }.compactMap { file -> (URL, Date)? in
      let values = try file.resourceValues(forKeys: keys)
      guard values.isRegularFile == true else { return nil }
      return (file, values.contentModificationDate ?? .distantPast)
    }
    for (file, _) in others.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.limit - 1) { try remove(file) }
  }

  private func remove(_ url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {}
  }

  private static func keyQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.cluefolk.images",
      kSecAttrAccount as String: "aes-gcm-key",
    ]
  }

  /// 256-bit key in the Keychain, this device only, created on first use.
  static func keychainKey() throws -> SymmetricKey {
    var query = keyQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
    // Only a confirmed miss creates a key: a locked Keychain must not orphan the stored copies.
    guard status == errSecItemNotFound else { throw CluefolkError.invalidResponse }
    let key = SymmetricKey(size: .bits256)
    var insert = keyQuery()
    insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw CluefolkError.invalidResponse }
    return key
  }
}
