import Foundation
import CryptoKit
import Darwin
import Security
import UIKit
import WebKit

/// Only the project ID is required. The widget is built into the SDK and the logo
/// is the app's own icon unless `logoImageName` names an image in the app bundle.
@objc(CLFOptions) public final class CluefolkOptions: NSObject {
  @objc public static let defaultAPIURL = URL(string: "https://cluefolk.com")!
  @objc public let projectId: String
  @objc public let apiURL: URL
  @objc public let logoImageName: String?
  @objc public convenience init(projectId: String) {
    self.init(projectId: projectId, apiURL: Self.defaultAPIURL, logoImageName: nil)
  }
  @objc public init(projectId: String, apiURL: URL, logoImageName: String?) {
    self.projectId = projectId
    self.apiURL = apiURL
    self.logoImageName = logoImageName
  }
}

struct StoredSession: Codable, Sendable {
  let token: String
  var expiresAt: Date
  let playerId: String
  let kind: String
  let externalUserId: String?
  var claimedExternalId: String
}

/// Keychain record bound to project and API origin.
struct StoredAccount: Codable, Sendable {
  let project: String
  let apiOrigin: String
  var session: StoredSession?
  var lastVerifiedExternalId: String?
}

enum CluefolkError: Error {
  case invalidConfiguration, notAuthenticated, notReady, identityRequired
  case requestFailed(Int)
  case invalidResponse, accountChanged, unsupportedCommand
}

@MainActor private final class IdentityWaiter {
  private var completion: CheckedContinuation<String, Error>?
  init(_ completion: CheckedContinuation<String, Error>) { self.completion = completion }
  func finish(_ token: String?, _ error: Error?) {
    guard let completion else { return }
    self.completion = nil
    if let error {
      completion.resume(throwing: error)
    } else if let token, !token.isEmpty {
      completion.resume(returning: token)
    } else {
      completion.resume(throwing: CluefolkError.notAuthenticated)
    }
  }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

@MainActor @objc(CLFEventListener) public protocol CluefolkEventListener: AnyObject {
  func onCluefolkReady()
  func onCluefolkOpened()
  func onCluefolkClosed()
  func onCluefolkUnreadChanged(_ count: Int)
  func onCluefolkIdentityTokenRequired(_ requestId: String)
  func onCluefolkConversationCreated(_ conversationId: String)
  func onCluefolkConversationStatusChanged(_ conversationId: String, status: String)
  func onCluefolkMessageSent(_ conversationId: String, messageId: String)
  func onCluefolkError(_ code: String)
}

@MainActor @objc(CLFCluefolk) public final class Cluefolk: NSObject {
  /// The SDK version, as tagged in the Swift package repository.
  @objc public nonisolated static let sdkVersion = "0.3.1"
  @objc public static let shared = Cluefolk()
  @objc public weak var eventListener: CluefolkEventListener? {
    didSet { if isReady { eventListener?.onCluefolkReady() } }
  }
  @objc public private(set) var isReady = false
  static let draftFields: Set<String> = [
    "body", "attachments", "clientId", "version", "visibility", "dirty", "mentions", "pendingClientId",
    "conversationId", "category", "fields", "context",
  ]
  private var options: CluefolkOptions?
  private var initialization: Task<Void, Never>?
  private var session: StoredSession?
  private var lastVerifiedExternalId: String?
  private var installSecret: String?
  private var provider: ((@escaping (String?, NSError?) -> Void) -> Void)?
  private var sessionCreation: Task<Void, Error>?
  private var sessionRefreshing = false
  private var generation = UUID()
  private var lifetime = UUID()
  private var pendingIdentity: (id: String, waiter: IdentityWaiter)?
  private var context: [String: Any] = [:]
  private var appearance: Appearance?
  private var logo: String?
  private var attributes: [String: Any] = [:]
  private var unset: Set<String> = []
  private var attributeTask: Task<Void, Never>?
  private var activeBatch: (path: String, body: [String: Any])?
  private var attributeRevision: Int64 = 0
  private weak var support: SupportController?
  private var opening: UUID?
  private var navigation: [String: String] = ["screen": "home", "id": ""]
  private var language = Locale.preferredLanguages.first ?? "en"
  /// Off: support turns the way the game does. On: it turns to everything the app allows.
  /// The theme's rotation decides.
  var freeRotation: Bool { appearance?.rotation == .free }
  /// The game's own player ID for anonymous players: nil until the game sets one,
  /// empty when the game cleared it. Memory only; logout forgets it.
  private var gamePlayerId: String?
  private var gamePlayerIdSyncing = false
  private var metadata: [String: Any] = [:]
  private var unreadPolling: Task<Void, Never>?
  private var unreadRefreshing = false
  private var unreadCount: Int?
  private var unreadObservedAt: TimeInterval?
  private var historyPages: [[String: Any]] = []
  private var historySyncId = UUID().uuidString
  private var historyEventCursor: String?
  private var pendingPush: [String: Any]?
  private weak var pushController: UIViewController?
  private lazy var network: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
  }()

  static func trusted(_ url: URL) -> Bool {
    guard url.host != nil, url.user == nil, url.password == nil, url.query == nil,
      url.fragment == nil
    else { return false }
    if url.scheme == "https" { return true }
    #if DEBUG
      return url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    #else
      return false
    #endif
  }
  /// The widget header shows the game's icon: the named image or the app icon,
  /// as a 192-pixel PNG data URL.
  static func gameIcon(named name: String?) -> String? {
    let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
    let primary = (icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String]
    guard let source = name.flatMap({ UIImage(named: $0) }) ?? primary?.last.flatMap({ UIImage(named: $0) })
    else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let png = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 192), format: format).pngData { _ in
      source.draw(in: CGRect(x: 0, y: 0, width: 192, height: 192))
    }
    return "data:image/png;base64," + png.base64EncodedString()
  }
  static func origin(_ url: URL) -> String {
    "\(url.scheme ?? "")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
  }

  @objc public func initialize(_ options: CluefolkOptions) throws {
    guard Self.trusted(options.apiURL), !options.projectId.isEmpty
    else { throw CluefolkError.invalidConfiguration }
    guard self.options == nil else { throw CluefolkError.invalidConfiguration }
    self.options = options
    var system = utsname()
    uname(&system)
    let model = withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    metadata = [
      "language": language,
      "platform": "ios", "sdkVersion": Self.sdkVersion, "osVersion": UIDevice.current.systemVersion,
      "deviceModel": model,
      "appVersion": String((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").prefix(128)),
      "appBuild": String((Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "").prefix(128)),
    ]
    for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(applicationStateChanged(_:)), name: name, object: nil)
    }
    let currentLifetime = lifetime
    initialization = Task {
      let stored = await Task.detached(priority: .utility) { Self.readAccount() }.value
      guard lifetime == currentLifetime else { return }
      if let stored, stored.project == options.projectId, stored.apiOrigin == Self.origin(options.apiURL) {
        lastVerifiedExternalId = stored.lastVerifiedExternalId
        if let value = stored.session, value.expiresAt > Date() { session = value }
      }
      isReady = true
      initialization = nil
      eventListener?.onCluefolkReady()
      applicationStateChanged()
      consumePendingPush()
      syncGamePlayerId()
    }
  }

  /// Optional: without a provider support starts anonymously; nil removes it.
  @objc public func setIdentityTokenProvider(
    _ provider: ((@escaping (String?, NSError?) -> Void) -> Void)?
  ) { self.provider = provider }

  /// Releases callbacks and transient state while preserving the Keychain session.
  @objc public func shutdown() {
    lifetime = UUID()
    isReady = false
    NotificationCenter.default.removeObserver(self)
    unreadPolling?.cancel()
    unreadPolling = nil
    pendingPush = nil
    pushController = nil
    initialization?.cancel()
    initialization = nil
    eventListener = nil
    provider = nil
    resetAccount(clearCredentials: false)
    lastVerifiedExternalId = nil
    installSecret = nil
    appearance = nil
    logo = nil
    options = nil
  }

  /// Answers identityTokenRequired. The SDK owns cancellation, timeout and account checks.
  @objc public func completeIdentityToken(_ requestId: String, token: String, error: String) {
    guard let pending = pendingIdentity, pending.id == requestId else { return }
    pendingIdentity = nil
    let failure = error.isEmpty ? nil : CluefolkError.notAuthenticated
    pending.waiter.finish(token.isEmpty ? nil : token, failure)
  }

  /// Signs in with an identity JWT; this device's anonymous history moves to the account.
  @objc public func loginWithIdentity(_ jwt: String, completion: @escaping (NSError?) -> Void) {
    guard isReady else {
      completion(CluefolkError.notReady as NSError)
      return
    }
    let currentLifetime = lifetime
    let previous = session
    resetAccount()
    let accountGeneration = generation
    Task {
      guard lifetime == currentLifetime else { return }
      if let previous { _ = try? await request("/sessions/logout", token: previous.token) }
      do {
        let body = try await sessionBody().merging(["identityToken": jwt]) { $1 }
        try await openSession("/sessions", body, generation: accountGeneration)
        if lifetime == currentLifetime { completion(nil) }
      } catch {
        guard lifetime == currentLifetime else { return }
        emitError(error)
        completion(error as NSError)
      }
    }
  }
  private func openSession(_ path: String, _ body: [String: Any], generation expected: UUID) async throws {
    guard generation == expected else { throw CluefolkError.accountChanged }
    let currentLifetime = lifetime
    let result = try await request(path, body: body)
    guard lifetime == currentLifetime else { throw CluefolkError.accountChanged }
    let external = result["externalUserId"] as? String
    guard let token = result["sessionToken"] as? String, !token.isEmpty,
      let date = result["sessionExpiresAt"] as? String, let expiresAt = Self.parseDate(date),
      let playerId = result["playerId"] as? String, !playerId.isEmpty,
      let kind = result["playerKind"] as? String, kind == "anonymous" || (kind == "verified" && external != nil),
      let unread = result["unreadCount"] as? Int,
      let cursor = result["eventCursor"] as? String,
      cursor.range(of: "^[0-9]{1,20}:[0-9]{1,19}$", options: .regularExpression) != nil
    else { throw CluefolkError.invalidResponse }
    guard generation == expected else {
      _ = try? await request("/sessions/logout", token: token)
      throw CluefolkError.accountChanged
    }
    let stored = StoredSession(
      token: token, expiresAt: expiresAt, playerId: playerId, kind: kind, externalUserId: external,
      claimedExternalId: result["claimedExternalId"] as? String ?? "")
    let verified = kind == "verified" ? external : lastVerifiedExternalId
    try persist(stored, verified)
    session = stored
    lastVerifiedExternalId = verified
    scheduleAttributes()
    syncGamePlayerId()
    historyPages = []
    historySyncId = UUID().uuidString
    historyEventCursor = cursor
    notifyUnreadChanged(unread)
    let pages = try await loadInitialHistory(result["history"] as? [String: Any], token: token, generation: expected)
    guard lifetime == currentLifetime, generation == expected else { throw CluefolkError.accountChanged }
    historyPages = pages
    historySyncId = UUID().uuidString
    consumePendingPush()
  }
  private func loadInitialHistory(_ first: [String: Any]?, token: String, generation expected: UUID) async throws -> [[String: Any]] {
    guard var page = first else { return [] }
    var pages: [[String: Any]] = []
    var cursors: Set<String> = []
    while true {
      guard generation == expected else { throw CluefolkError.accountChanged }
      guard page["conversations"] is [[String: Any]], page["messages"] is [[String: Any]],
        let next = page["nextCursor"] as? String, next.count <= 1024 else { throw CluefolkError.invalidResponse }
      pages.append(page)
      if next.isEmpty { return pages }
      guard cursors.insert(next).inserted,
        let encoded = next.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { throw CluefolkError.invalidResponse }
      page = try await request("/history?cursor=" + encoded, method: "GET", token: token)
    }
  }
  private func ensureSession() async throws {
    if let session, session.expiresAt > Date().addingTimeInterval(30) {
      if session.expiresAt < Date().addingTimeInterval(7 * 86_400) { refreshSession(session) }
      return
    }
    if let sessionCreation { return try await sessionCreation.value }
    let expected = generation
    let task = Task { @MainActor in try await self.createSession(generation: expected) }
    sessionCreation = task
    defer { if generation == expected { sessionCreation = nil } }
    try await task.value
  }
  /// Verified when the game can sign in; otherwise, or when its backend is down, anonymous.
  private func createSession(generation expected: UUID) async throws {
    var body = try await sessionBody()
    if provider != nil || lastVerifiedExternalId != nil {
      let stale = session?.token
      if let token = try? await identityToken(), generation == expected {
        do {
          return try await openSession("/sessions", body.merging(["identityToken": token]) { $1 }, generation: expected)
        } catch let error where generation == expected && session?.token == stale && Self.transient(error) {
          // Falls back only when no session was issued; a failed history page keeps the verified one.
        }
      }
      guard generation == expected else { throw CluefolkError.accountChanged }
      eventListener?.onCluefolkError("IDENTITY_UNAVAILABLE")
    }
    // The game's player ID wins over the last account's; one the game cleared sends none.
    let claimed = gamePlayerId ?? lastVerifiedExternalId ?? ""
    if !claimed.isEmpty { body["claimedExternalId"] = claimed }
    try await openSession("/sessions/anonymous", body, generation: expected)
  }
  private func identityToken() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      let waiter = IdentityWaiter(continuation)
      let requestId = UUID().uuidString
      pendingIdentity = (requestId, waiter)
      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        waiter.finish(nil, CluefolkError.notAuthenticated)
        if pendingIdentity?.id == requestId { pendingIdentity = nil }
      }
      if let provider {
        provider { token, error in
          Task { @MainActor in
            waiter.finish(token, error)
            if self.pendingIdentity?.id == requestId { self.pendingIdentity = nil }
          }
        }
      } else {
        eventListener?.onCluefolkIdentityTokenRequired(requestId)
      }
    }
  }
  private static func transient(_ error: Error) -> Bool {
    if case CluefolkError.requestFailed(let status) = error { return status == 401 || status >= 500 }
    return error is URLError
  }
  /// The install secret identifies this device's anonymous player and survives logout.
  private func sessionBody() async throws -> [String: Any] {
    guard let options else { throw CluefolkError.invalidConfiguration }
    if installSecret == nil {
      let account = Self.installAccount(options)
      let value = await Task.detached(priority: .utility) { Self.readInstallSecret(account) }.value
      guard self.options === options else { throw CluefolkError.accountChanged }
      installSecret = value
    }
    guard let installSecret else { throw CluefolkError.invalidResponse }
    return ["projectId": options.projectId, "installSecret": installSecret]
  }
  /// Slides the 30-day native session so support keeps working while the game backend is down.
  private func refreshSession(_ current: StoredSession) {
    guard !sessionRefreshing else { return }
    sessionRefreshing = true
    let expected = generation
    Task {
      var expiresAt: Date?
      var revoked = false
      do {
        let result = try await request("/sessions/refresh", token: current.token)
        expiresAt = (result["sessionExpiresAt"] as? String).flatMap(Self.parseDate)
      } catch CluefolkError.requestFailed(401) { revoked = true } catch {}
      guard generation == expected else { return }
      sessionRefreshing = false
      if revoked { return dropSession(current.token) }
      guard let expiresAt, session?.token == current.token else { return }
      session?.expiresAt = expiresAt
      try? persist(session, lastVerifiedExternalId)
    }
  }
  private func dropSession(_ token: String) {
    guard session?.token == token else { return }
    session = nil
    try? persist(nil, lastVerifiedExternalId)
  }
  @objc public func open(from controller: UIViewController) {
    open(from: controller, screen: "home", id: "")
  }
  /// An empty id opens the player's current chat.
  @objc public func openConversation(_ conversationId: String, from controller: UIViewController) {
    open(from: controller, screen: "conversation", id: conversationId)
  }
  private func open(from controller: UIViewController, screen: String, id: String) {
    guard requireReady() else { return }
    guard id.count <= 128 else { eventListener?.onCluefolkError("INVALID_ARGUMENT"); return }
    navigation = ["screen": screen, "id": id]
    if let support { support.navigate(navigation); return }
    guard opening == nil else { return }
    let requestId = UUID()
    opening = requestId
    let expected = generation
    Task { [weak controller] in
      guard generation == expected, opening == requestId else { return }
      do {
        try await ensureSession()
        guard generation == expected, opening == requestId, support == nil, let options else { return }
        opening = nil
        guard let controller, controller.viewIfLoaded?.window != nil,
          !controller.isBeingDismissed
        else { eventListener?.onCluefolkError("NO_PRESENTING_CONTROLLER"); return }
        if logo == nil { logo = Self.gameIcon(named: options.logoImageName) }
        let view = SupportController(
          sdk: self, apiURL: options.apiURL,
          game: SupportController.orientations(of: controller, free: freeRotation))
        view.modalPresentationStyle = .fullScreen
        support = view
        controller.present(view, animated: true)
        eventListener?.onCluefolkOpened()
      } catch {
        guard generation == expected, opening == requestId else { return }
        opening = nil
        emitError(error)
      }
    }
  }
  @objc public func close() {
    pendingPush = nil
    closeSupport()
  }
  private func closeSupport() {
    opening = nil
    guard let support else { return }
    self.support = nil
    support.tearDown()
    support.dismiss(animated: true)
    eventListener?.onCluefolkClosed()
  }
  fileprivate func supportDismissed(_ view: SupportController) {
    guard support === view else { return }
    support = nil
    view.tearDown()
    eventListener?.onCluefolkClosed()
  }
  fileprivate func supportTerminated(_ view: SupportController) {
    guard support === view else { return }
    close()
    eventListener?.onCluefolkError("WEB_CONTENT_TERMINATED")
  }
  @objc public func setLanguage(_ value: String) {
    guard value.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil,
      value.count <= 64 else { eventListener?.onCluefolkError("INVALID_LANGUAGE"); return }
    language = value
    metadata["language"] = value
    support?.setLanguage(value)
  }
  /// The game's own player ID. Staff see it as unverified on an anonymous player; verified
  /// players are identified by their identity token instead. nil or blank clears it.
  /// Kept in memory until logout and sent with the anonymous session; it never opens one.
  @objc public func setPlayerId(_ playerId: String?) {
    guard let value = Self.normalizedPlayerId(playerId) else {
      eventListener?.onCluefolkError("INVALID_ARGUMENT")
      return
    }
    gamePlayerId = value
    syncGamePlayerId()
  }
  /// The player ID as the server stores it: trimmed, empty when cleared. nil when the
  /// server would reject it: over 256 characters or a line break or NUL inside.
  nonisolated static func normalizedPlayerId(_ value: String?) -> String? {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden: Set<Unicode.Scalar> = ["\r", "\n", "\0"]
    guard trimmed.unicodeScalars.count <= 256, !trimmed.unicodeScalars.contains(where: forbidden.contains)
    else { return nil }
    return trimmed
  }
  /// Brings an existing anonymous session's unverified ID in line with the game's player ID.
  private func syncGamePlayerId() {
    guard isReady, !gamePlayerIdSyncing, let claimed = gamePlayerId, let current = session,
      current.kind == "anonymous", current.claimedExternalId != claimed, current.expiresAt > Date()
    else { return }
    gamePlayerIdSyncing = true
    let expected = generation
    Task {
      var failure: Error?
      do {
        let result = try await request(
          "/players/me", method: "PATCH", token: current.token, body: ["claimedExternalId": claimed])
        guard generation == expected else { return }
        if session?.token == current.token {
          session?.claimedExternalId = result["claimedExternalId"] as? String ?? claimed
          try? persist(session, lastVerifiedExternalId)
        }
      } catch {
        guard generation == expected else { return }
        failure = error
      }
      gamePlayerIdSyncing = false
      if let failure {
        if case CluefolkError.requestFailed(401) = failure {
          dropSession(current.token)  // The next anonymous session takes the ID with it.
        } else if case CluefolkError.requestFailed(409) = failure {
          // PLAYER_VERIFIED: the player has signed in; the unverified ID no longer applies.
        } else {
          emitError(failure)
        }
      }
      // Only a newer ID or session is sent again; a failed one waits for the next.
      if gamePlayerId != claimed || session?.token != current.token { syncGamePlayerId() }
    }
  }
  @objc private func applicationStateChanged(_ notification: Notification? = nil) {
    unreadPolling?.cancel()
    unreadPolling = nil
    guard notification?.name != UIApplication.willResignActiveNotification,
      isReady, UIApplication.shared.applicationState == .active else { return }
    consumePendingPush()
    unreadPolling = Task {
      while !Task.isCancelled {
        if unreadObservedAt == nil || ProcessInfo.processInfo.systemUptime - (unreadObservedAt ?? 0) >= 30 {
          refreshUnreadCount()
        }
        consumePendingPush()
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
      }
    }
  }
  @objc public func refreshUnreadCount() {
    guard isReady, session != nil, !unreadRefreshing else { return }
    unreadRefreshing = true
    let expected = generation
    getUnreadCount { [weak self] count, error in
      guard let self, generation == expected else { return }
      unreadRefreshing = false
      if error == nil { notifyUnreadChanged(count) }
    }
  }
  private func notifyUnreadChanged(_ count: Int) {
    guard count >= 0 else { return }
    unreadObservedAt = ProcessInfo.processInfo.systemUptime
    guard unreadCount != count else { return }
    unreadCount = count
    eventListener?.onCluefolkUnreadChanged(count)
  }
  @discardableResult @objc public func handlePush(_ data: [String: Any]) -> Bool {
    guard data["origin"] as? String == "cluefolk" else { return false }
    if matchesPush(data) { refreshUnreadCount() }
    return true
  }
  @discardableResult @objc public func openFromPush(_ data: [String: Any], from controller: UIViewController) -> Bool {
    guard data["origin"] as? String == "cluefolk" else { return false }
    pendingPush = data
    pushController = controller
    consumePendingPush()
    return true
  }
  private func matchesPush(_ data: [String: Any]) -> Bool {
    guard let options, let playerId = session?.playerId, !playerId.isEmpty else { return false }
    return data["playerId"] as? String == playerId && data["projectId"] as? String == options.projectId
  }
  private func consumePendingPush() {
    guard isReady, let playerId = session?.playerId, !playerId.isEmpty, let data = pendingPush,
      UIApplication.shared.applicationState == .active, let controller = pushController,
      controller.viewIfLoaded?.window != nil else { return }
    pendingPush = nil
    guard matchesPush(data), let id = data["conversationId"] as? String, (1...128).contains(id.count) else { return }
    openConversation(id, from: controller)
  }
  /// The theme shipped with the build, made by `AppearanceBuilder`; nil restores the default.
  /// Applies on the next open, including how support turns. Kept until `shutdown()`.
  @objc public func setAppearance(_ appearance: Appearance?) {
    self.appearance = appearance
  }

  @objc public func setConversationContext(_ values: [String: Any]) throws {
    guard isReady else { throw CluefolkError.notReady }
    let data = try JSONSerialization.data(withJSONObject: values)
    guard data.count <= 16_384 else { throw CluefolkError.invalidConfiguration }
    var merged = values
    merged["_cluefolk"] = metadata
    guard try JSONSerialization.data(withJSONObject: merged).count <= 16_384 else { throw CluefolkError.invalidConfiguration }
    context = values
  }
  @objc public func setAttributes(_ values: [String: Any]) throws {
    guard isReady else { throw CluefolkError.notReady }
    var merged = attributes
    merged.merge(values) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: merged)
    guard Set(merged.keys).union(unset).count <= 64, data.count <= 15_000 else {
      throw CluefolkError.invalidConfiguration
    }
    attributes = merged
    unset.subtract(values.keys)
    scheduleAttributes()
  }
  @objc public func unsetAttributes(_ keys: [String]) throws {
    guard isReady else { throw CluefolkError.notReady }
    guard Set(keys).union(unset).union(attributes.keys).count <= 64 else {
      throw CluefolkError.invalidConfiguration
    }
    for key in keys {
      attributes.removeValue(forKey: key)
      unset.insert(key)
    }
    scheduleAttributes()
  }
  private func scheduleAttributes(delay: UInt64 = 300_000_000) {
    guard session != nil, attributeTask == nil,
      activeBatch != nil || !attributes.isEmpty || !unset.isEmpty
    else { return }
    let expected = generation
    attributeTask = Task {
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard generation == expected else { return }
      do { try await ensureSession() } catch {
        guard generation == expected else { return }
        attributeTask = nil
        emitError(error)
        return
      }
      guard generation == expected, let session else { return }
      if activeBatch == nil {
        attributeRevision = max(attributeRevision + 1, Int64(Date().timeIntervalSince1970 * 1000))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: Any] = [
          "observedAt": formatter.string(from: Date()), "revision": attributeRevision,
          "batchId": UUID().uuidString,
        ]
        if !attributes.isEmpty {
          body["attributes"] = attributes
          attributes = [:]
          activeBatch = ("/players/me/attributes", body)
        } else {
          body["keys"] = Array(unset)
          unset = []
          activeBatch = ("/players/me/attributes/unset", body)
        }
      }
      guard let batch = activeBatch else {
        attributeTask = nil
        return
      }
      do {
        _ = try await request(
          batch.path, method: batch.path.hasSuffix("/unset") ? "POST" : "PATCH",
          token: session.token, body: batch.body)
        guard generation == expected else { return }
        activeBatch = nil
        attributeTask = nil
        scheduleAttributes()
      } catch {
        guard generation == expected else { return }
        if case CluefolkError.requestFailed(let status) = error {
          if status == 401 {
            dropSession(session.token)
            do { try await ensureSession() } catch { emitError(error) }
            guard generation == expected else { return }
          } else if (400..<500).contains(status) && status != 429 {
            activeBatch = nil
          }
        }
        attributeTask = nil
        emitError(error)
        // Keep the original revision and batch ID for transport retries.
        scheduleAttributes(delay: 5_000_000_000)
      }
    }
  }
  @objc public func getUnreadCount(_ completion: @escaping (Int, NSError?) -> Void) {
    guard isReady else {
      completion(0, CluefolkError.notReady as NSError)
      return
    }
    let expected = generation
    let currentLifetime = lifetime
    Task {
      guard lifetime == currentLifetime else { return }
      do {
        guard generation == expected else { throw CluefolkError.accountChanged }
        let previousToken = session?.token
        try await ensureSession()
        guard generation == expected, let session else { throw CluefolkError.accountChanged }
        if session.token != previousToken, let unreadCount {
          if lifetime == currentLifetime { completion(unreadCount, nil) }
          return
        }
        let result = try await request("/unread-count", method: "GET", token: session.token)
        guard generation == expected else { throw CluefolkError.accountChanged }
        if lifetime == currentLifetime { completion(result["count"] as? Int ?? 0, nil) }
      } catch {
        if lifetime == currentLifetime { completion(0, error as NSError) }
      }
    }
  }
  /// Ends the session and forgets the account. The install secret stays, so the next
  /// anonymous session continues this device's history.
  @objc public func logout() {
    guard requireReady() else { return }
    let previous = session
    pendingPush = nil
    lastVerifiedExternalId = nil
    gamePlayerId = nil
    Task { try? await SecureDraftStore.shared.clear() }
    Task { try? await SecureImageStore.shared.clear() }
    resetAccount()
    if let previous { Task { _ = try? await request("/sessions/logout", token: previous.token) } }
  }
  private func resetAccount(clearCredentials: Bool = true) {
    generation = UUID()
    pendingIdentity?.waiter.finish(nil, CluefolkError.accountChanged)
    pendingIdentity = nil
    sessionCreation?.cancel()
    sessionCreation = nil
    sessionRefreshing = false
    gamePlayerIdSyncing = false
    attributeTask?.cancel()
    attributeTask = nil
    activeBatch = nil
    attributes = [:]
    unset = []
    session = nil
    unreadRefreshing = false
    historyPages = []
    historySyncId = UUID().uuidString
    historyEventCursor = nil
    if unreadCount != nil { notifyUnreadChanged(0) }
    unreadCount = nil
    unreadObservedAt = nil
    context = [:]
    closeSupport()
    if clearCredentials { try? persist(nil, lastVerifiedExternalId) }
  }
  static func bridgeRequest(_ value: [String: Any]) -> (id: String, type: String, payload: [String: Any])? {
    guard Set(value.keys) == ["protocol", "version", "requestId", "type", "payload"],
      value["protocol"] as? String == BridgeProtocol.protocolName, value["version"] as? Int == BridgeProtocol.version,
      let id = value["requestId"] as? String, (1...128).contains(id.count),
      let type = value["type"] as? String, BridgeProtocol.nativeRequests.contains(type),
      let payload = value["payload"] as? [String: Any]
    else { return nil }
    return (id, type, payload)
  }
  func bootstrapPayload(code: String, apiURL: URL, session: StoredSession) -> [String: Any] {
    var combined = context
    combined["_cluefolk"] = metadata
    var result: [String: Any] = [
      "code": code, "apiBaseUrl": Self.origin(apiURL), "context": combined, "language": language,
      "navigation": navigation, "unreadCount": unreadCount as Any? ?? NSNull(), "historySyncId": historySyncId,
      "historyPageCount": historyPages.count,
      "player": [
        "kind": session.kind, "externalUserId": session.externalUserId as Any? ?? NSNull(),
        "claimedExternalId": session.claimedExternalId,
      ],
    ]
    if let appearance { result["appearance"] = appearance.json }
    if let logo { result["logo"] = logo }
    if let historyEventCursor { result["eventCursor"] = historyEventCursor }
    return result
  }
  fileprivate func handle(_ value: [String: Any], from view: WKWebView) async throws -> [String: Any] {
    guard let message = Self.bridgeRequest(value) else { throw CluefolkError.invalidResponse }
    let payload = message.payload
    var result: [String: Any] = [:]
    var responseType = BridgeProtocol.sdkAck
    do {
      guard support?.webView === view else { throw CluefolkError.accountChanged }
      let expected = generation
      switch message.type {
      case BridgeProtocol.nativeReady, BridgeProtocol.nativeAuthRequired:
        try await ensureSession()
        guard let current = session else { throw CluefolkError.notAuthenticated }
        do {
          result = try await request("/sessions/bootstrap", token: current.token)
        } catch CluefolkError.requestFailed(401) {
          dropSession(current.token)
          try await ensureSession()
          guard let renewed = session else { throw CluefolkError.notAuthenticated }
          result = try await request("/sessions/bootstrap", token: renewed.token)
        }
        guard generation == expected, support?.webView === view, let options, let active = session,
          let code = result["bootstrapCode"] as? String
        else { throw CluefolkError.accountChanged }
        result = bootstrapPayload(code: code, apiURL: options.apiURL, session: active)
        responseType = BridgeProtocol.sdkBootstrap
      case BridgeProtocol.nativeDraftGet, BridgeProtocol.nativeDraftPut:
        guard let options, let player = session?.playerId,
          let key = payload["key"] as? String, key == "new" || UUID(uuidString: key) != nil else { throw CluefolkError.invalidResponse }
        let namespace = Self.storageNamespace(options, player: player)
        do {
          if message.type == BridgeProtocol.nativeDraftPut {
            var data: Data?
            if let content = payload["content"] as? [String: Any] {
              guard Set(content.keys).isSubset(of: Self.draftFields) else { throw CluefolkError.invalidResponse }
              data = try JSONSerialization.data(withJSONObject: content)
              guard data!.count <= 102_400 else { throw CluefolkError.invalidResponse }
            }
            try await SecureDraftStore.shared.write(namespace: namespace, key: key, content: data)
          } else if let data = try await SecureDraftStore.shared.read(namespace: namespace, key: key) {
            result["content"] = try JSONSerialization.jsonObject(with: data)
          } else { result["content"] = NSNull() }
          guard generation == expected, support?.webView === view else { throw CluefolkError.accountChanged }
        } catch {
          responseType = BridgeProtocol.sdkError
          result = ["code": "DRAFT_STORAGE_UNAVAILABLE"]
        }
      case BridgeProtocol.nativeImagePut, BridgeProtocol.nativeImageGet:
        (responseType, result) = try await image(message.type, payload, from: view, generation: expected)
      case BridgeProtocol.nativeHistoryPage:
        guard payload["syncId"] as? String == historySyncId, let index = payload["index"] as? Int,
          historyPages.indices.contains(index) else { throw CluefolkError.invalidResponse }
        result = historyPages[index]
      case BridgeProtocol.nativeClose: close()
      case BridgeProtocol.nativeUnreadCountChanged:
        guard let count = payload["count"] as? Int, count >= 0 else {
          throw CluefolkError.invalidResponse
        }
        notifyUnreadChanged(count)
      case BridgeProtocol.nativeConversationCreated:
        eventListener?.onCluefolkConversationCreated(try identifier(payload, "conversationId"))
      case BridgeProtocol.nativeConversationStatusChanged:
        guard let status = payload["status"] as? String,
          ["open", "pending_agent", "pending_player", "resolved", "closed"].contains(status) else { throw CluefolkError.invalidResponse }
        eventListener?.onCluefolkConversationStatusChanged(try identifier(payload, "conversationId"), status: status)
      case BridgeProtocol.nativeMessageSent:
        eventListener?.onCluefolkMessageSent(try identifier(payload, "conversationId"), messageId: try identifier(payload, "messageId"))
      default: throw CluefolkError.unsupportedCommand
      }
    } catch {
      responseType = BridgeProtocol.sdkError
      result = ["code": Self.errorCode(error)]
    }
    return [
      "protocol": BridgeProtocol.protocolName, "version": BridgeProtocol.version, "requestId": message.id,
      "type": responseType, "payload": result,
    ]
  }
  /// Drafts and image copies of one account: project, API origin and player.
  private static func storageNamespace(_ options: CluefolkOptions, player: String) -> String {
    options.projectId + "/" + origin(options.apiURL) + "/" + player
  }
  /// native.imagePut / native.imageGet: the player's own sent images, kept as encrypted
  /// previews on this device and bound to the current account.
  private func image(
    _ type: String, _ payload: [String: Any], from view: WKWebView, generation expected: UUID
  ) async throws -> (String, [String: Any]) {
    guard isReady, let options, let player = session?.playerId else {
      return (BridgeProtocol.sdkError, ["code": "NOT_AUTHENTICATED"])
    }
    let put = type == BridgeProtocol.nativeImagePut
    guard Set(payload.keys) == (put ? ["id", "data"] : ["id"]), let id = payload["id"] as? String,
      Self.isImageId(id) else { throw CluefolkError.invalidResponse }
    let upload = put ? Self.decodeImage(payload["data"]) : nil
    if put && upload == nil { throw CluefolkError.invalidResponse }
    let namespace = Self.storageNamespace(options, player: player)
    var stored: Data?
    var failed = false
    do {
      if let upload {
        try await SecureImageStore.shared.write(namespace: namespace, id: id, data: upload)
      } else {
        stored = try await SecureImageStore.shared.read(namespace: namespace, id: id)
      }
    } catch { failed = true }
    // A reply for a previous account or page is dropped.
    guard generation == expected, support?.webView === view else { throw CluefolkError.accountChanged }
    if failed { return (BridgeProtocol.sdkError, ["code": "IMAGE_STORAGE_UNAVAILABLE"]) }
    if put { return (BridgeProtocol.sdkAck, [:]) }
    return (BridgeProtocol.sdkAck, ["data": stored.map { $0.base64EncodedString() as Any } ?? NSNull()])
  }
  /// The attachment ID: a lowercase UUID.
  nonisolated static func isImageId(_ id: String) -> Bool {
    id.utf8.count == 36
      && id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
  }
  /// A JPEG preview: standard base64 (padding optional) of at most 120,000 characters,
  /// decoding to at most 90,000 bytes that start with FF D8 FF.
  nonisolated static func decodeImage(_ value: Any?) -> Data? {
    guard let text = value as? String, text.utf8.count <= 120_000 else { return nil }
    let padding = text.utf8.reversed().prefix { $0 == UInt8(ascii: "=") }.count
    let digits = text.utf8.dropLast(padding)
    let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    guard !digits.isEmpty, padding <= 2, digits.count % 4 != 1, digits.allSatisfy(alphabet.contains),
      let data = Data(base64Encoded: String(decoding: digits, as: UTF8.self) + String(repeating: "=", count: (4 - digits.count % 4) % 4)),
      SecureImageStore.isJPEG(data)
    else { return nil }
    return data
  }
  private func identifier(_ payload: [String: Any], _ key: String) throws -> String {
    guard let value = payload[key] as? String, (1...128).contains(value.count) else { throw CluefolkError.invalidResponse }
    return value
  }
  private func request(
    _ path: String, method: String = "POST", token: String? = nil, body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    guard let options, let url = URL(string: Self.origin(options.apiURL) + "/v1/sdk" + path) else {
      throw CluefolkError.invalidConfiguration
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, response) = try await network.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw CluefolkError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      if http.statusCode == 403, (failure?["error"] as? [String: Any])?["code"] as? String == "IDENTITY_REQUIRED" {
        throw CluefolkError.identityRequired
      }
      throw CluefolkError.requestFailed(http.statusCode)
    }
    guard data.count <= 1_048_576,
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw CluefolkError.invalidResponse }
    return result
  }
  private func emitError(_ error: Error) { eventListener?.onCluefolkError(Self.errorCode(error)) }
  private static func errorCode(_ error: Error) -> String {
    if case CluefolkError.identityRequired = error { return "IDENTITY_REQUIRED" }
    return "SUPPORT_UNAVAILABLE"
  }
  private func requireReady() -> Bool {
    guard isReady else {
      eventListener?.onCluefolkError("NOT_READY")
      return false
    }
    return true
  }
  private static func parseDate(_ string: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }
  /// 32 random bytes, base64url without padding (43 characters).
  nonisolated static func makeInstallSecret() -> String? {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  private static func installAccount(_ options: CluefolkOptions) -> String {
    let binding = [options.projectId, origin(options.apiURL)].joined(separator: "\n")
    return "install-" + SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  nonisolated private static func keychainQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.cluefolk.sdk",
      kSecAttrAccount as String: account,
    ]
  }
  nonisolated private static func keychainRead(_ account: String) -> (status: OSStatus, data: Data?) {
    var q = keychainQuery(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    return (status, result as? Data)
  }
  nonisolated private static func keychainWrite(_ account: String, _ data: Data?) -> Bool {
    var q = keychainQuery(account)
    let deleted = SecItemDelete(q as CFDictionary)
    guard let data else { return deleted == errSecSuccess || deleted == errSecItemNotFound }
    q[kSecValueData as String] = data
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }
  nonisolated private static func readInstallSecret(_ account: String) -> String? {
    let stored = keychainRead(account)
    if let data = stored.data, let value = String(data: data, encoding: .utf8), value.count == 43 { return value }
    // Only a confirmed miss creates a secret: a locked Keychain must not replace this device's player.
    guard stored.status == errSecItemNotFound || stored.status == errSecSuccess, let value = makeInstallSecret(),
      keychainWrite(account, Data(value.utf8))
    else { return nil }
    return value
  }
  private func persist(_ session: StoredSession?, _ lastVerified: String?) throws {
    guard let options else { throw CluefolkError.invalidConfiguration }
    var data: Data?
    if session != nil || lastVerified != nil {
      data = try JSONEncoder().encode(StoredAccount(
        project: options.projectId, apiOrigin: Self.origin(options.apiURL),
        session: session, lastVerifiedExternalId: lastVerified))
    }
    guard Self.keychainWrite("native-session", data) else { throw CluefolkError.invalidResponse }
  }
  nonisolated private static func readAccount() -> StoredAccount? {
    guard let data = keychainRead("native-session").data else { return nil }
    return try? JSONDecoder().decode(StoredAccount.self, from: data)
  }
}

@MainActor
final class SupportController: UIViewController, WKNavigationDelegate,
  WKScriptMessageHandlerWithReply
{
  let sdk: Cluefolk
  let url = WidgetSchemeHandler.entry
  /// Serves the widget built into the SDK for the API origin of the options.
  private let widget: WidgetSchemeHandler
  private(set) var webView: WKWebView!
  /// The game's orientations and its current one: support turns the way the
  /// game does — landscape, portrait or both.
  private let game: (mask: UIInterfaceOrientationMask, current: UIInterfaceOrientation)
  init(
    sdk: Cluefolk, apiURL: URL,
    game: (mask: UIInterfaceOrientationMask, current: UIInterfaceOrientation) = (.all, .portrait)
  ) {
    self.sdk = sdk
    self.game = game
    widget = WidgetSchemeHandler(apiURL: apiURL)
    super.init(nibName: nil, bundle: nil)
  }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { game.mask }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { game.current }
  /// The orientations of the game's window: what the app allows for it, what its root
  /// screen supports and the current one.
  static func orientations(of controller: UIViewController, free: Bool = false)
    -> (mask: UIInterfaceOrientationMask, current: UIInterfaceOrientation)
  {
    let window = controller.view.window
    return orientations(
      app: window.map { UIApplication.shared.supportedInterfaceOrientations(for: $0) } ?? .all,
      game: (window?.rootViewController ?? controller).supportedInterfaceOrientations,
      now: window?.windowScene?.interfaceOrientation ?? .unknown, free: free)
  }
  /// By default what the app allows and the game supports; with free rotation everything
  /// the app allows. The start orientation is the current one when allowed, and always one of them.
  static func orientations(
    app: UIInterfaceOrientationMask, game: UIInterfaceOrientationMask, now: UIInterfaceOrientation,
    free: Bool
  ) -> (mask: UIInterfaceOrientationMask, current: UIInterfaceOrientation) {
    let both = app.intersection(game)
    let mask = free || both.isEmpty ? app : both
    let order: [(UIInterfaceOrientation, UIInterfaceOrientationMask)] = [
      (.portrait, .portrait), (.landscapeRight, .landscapeRight),
      (.landscapeLeft, .landscapeLeft), (.portraitUpsideDown, .portraitUpsideDown),
    ]
    let current =
      order.first { $0.0 == now && mask.contains($0.1) }?.0
      ?? order.first { mask.contains($0.1) }?.0 ?? .portrait
    return (mask, current)
  }
  required init?(coder: NSCoder) { nil }
  override func loadView() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.setURLSchemeHandler(widget, forURLScheme: WidgetSchemeHandler.scheme)
    config.userContentController.addScriptMessageHandler(
      self, contentWorld: .page, name: "cluefolk")
    webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    if #available(iOS 16.4, *) { webView.isInspectable = false }
    view = webView
    webView.load(URLRequest(url: url))
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || presentingViewController == nil { sdk.supportDismissed(self) }
  }
  func tearDown() {
    guard let webView else { return }
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "cluefolk", contentWorld: .page)
    webView.navigationDelegate = nil
    webView.stopLoading()
  }
  func navigate(_ target: [String: String]) { dispatch("cluefolk:navigate", target) }
  func setLanguage(_ language: String) { dispatch("cluefolk:language", language) }
  private func dispatch(_ name: String, _ value: Any) {
    guard let webView else { return }
    webView.callAsyncJavaScript("window.dispatchEvent(new CustomEvent(name, {detail: value}))",
      arguments: ["name": name, "value": value], in: nil, in: .page, completionHandler: nil)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard action.targetFrame?.isMainFrame == true, let destination = action.request.url,
      Cluefolk.origin(destination) == Cluefolk.origin(url), destination.user == nil
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard message.frameInfo.isMainFrame, message.webView === webView,
      message.frameInfo.securityOrigin.protocol == url.scheme,
      message.frameInfo.securityOrigin.host == url.host,
      (message.frameInfo.securityOrigin.port == 0
        ? (message.frameInfo.securityOrigin.protocol == "https" ? 443 : 80)
        : message.frameInfo.securityOrigin.port)
        == (url.port ?? (url.scheme == "https" ? 443 : 80)),
      let body = message.body as? [String: Any],
      let raw = try? JSONSerialization.data(withJSONObject: body), raw.count <= 131_072
    else {
      replyHandler(nil, "UNTRUSTED_BRIDGE")
      return
    }
    Task {
      do {
        let result = try await sdk.handle(body, from: webView)
        replyHandler(result, nil)
      } catch { replyHandler(nil, "SUPPORT_UNAVAILABLE") }
    }
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    sdk.supportTerminated(self)
  }
}

// Keychain I/O is isolated from UIKit. Accounts have distinct authenticated
// namespaces and no plaintext draft is persisted by WKWebView.
private actor SecureDraftStore {
  static let shared = SecureDraftStore()
  private let service = "com.cluefolk.drafts"
  private func account(namespace: String, key: String) -> String {
    SHA256.hash(data: Data((namespace + "/" + key).utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func query(_ account: String? = nil) -> [String: Any] {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    if let account { q[kSecAttrAccount as String] = account }
    return q
  }
  func read(namespace: String, key: String) throws -> Data? {
    var q = query(account(namespace: namespace, key: key))
    q[kSecReturnData as String] = true
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let record = result as? [String: Any],
      let modified = record[kSecAttrModificationDate as String] as? Date,
      let data = record[kSecValueData as String] as? Data, data.count <= 102_400
    else { throw CluefolkError.invalidResponse }
    if modified < Date().addingTimeInterval(-30 * 86400) { return nil }
    return data
  }
  func write(namespace: String, key: String, content: Data?) throws {
    let q = query(account(namespace: namespace, key: key))
    guard let content else {
      let status = SecItemDelete(q as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw CluefolkError.invalidResponse }
      return
    }
    guard content.count <= 102_400 else { throw CluefolkError.invalidResponse }
    let update: [String: Any] = [kSecValueData as String: content]
    var status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var insert = q
      insert[kSecValueData as String] = content
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(insert as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw CluefolkError.invalidResponse }
    try prune(keeping: account(namespace: namespace, key: key))
  }
  private func prune(keeping current: String) throws {
    var q = query()
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess, let records = result as? [[String: Any]] else { throw CluefolkError.invalidResponse }
    let sorted = records.sorted { ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast) > ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast) }
    var retained = 1
    for record in sorted {
      guard let name = record[kSecAttrAccount as String] as? String else { continue }
      if name == current { continue }
      let date = record[kSecAttrModificationDate as String] as? Date ?? .distantPast
      if retained < 20 && date >= Date().addingTimeInterval(-30 * 86400) { retained += 1; continue }
      let status = SecItemDelete(query(name) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw CluefolkError.invalidResponse }
    }
  }
  func clear() throws {
    let status = SecItemDelete(query() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw CluefolkError.invalidResponse }
  }
}
