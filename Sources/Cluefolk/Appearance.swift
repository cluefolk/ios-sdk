import Foundation

/// Which colors support uses: the device's setting, or always the light or the dark theme.
@objc(CLFAppearanceMode) public enum AppearanceMode: Int {
  case system, light, dark
}

/// How support turns. `game`: like the game — landscape, portrait or both. `free`: to every
/// orientation the app allows (Info.plist), whatever the game's screen supports.
@objc(CLFAppearanceRotation) public enum AppearanceRotation: Int {
  case game, free
}

/// Why a theme was rejected. The checks are the widget's, so a theme that builds is one
/// the widget shows. Lengths count UTF-16 code units, as the widget does.
@objc(CLFAppearanceError) public enum AppearanceError: Int, Error {
  /// Not a theme: not JSON, not an object, a version other than 2, a key the theme does not
  /// have, a value of the wrong type, or a mode or rotation the theme does not know.
  case invalidJSON = 1
  /// The title is blank or longer than 100.
  case invalidTitle
  /// A theme does not have exactly its five colors, each as #RRGGBB.
  case invalidColors
  /// More than four blocks, a type that is unknown or appears twice, a title longer than 100,
  /// a text longer than 1000, more than 12 topics, or topics outside the topics block.
  case invalidBlock
  /// A topic with a blank label or one longer than 80, a category that is not a category key,
  /// or an icon that is neither up to 32 characters without < and > nor a PNG/JPEG data URL.
  case invalidTopic
  /// Larger than 1.5 MB.
  case tooLarge
}

extension AppearanceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidJSON: return "Invalid appearance file (v2 required)."
    case .invalidTitle: return "The title must be 1 to 100 characters."
    case .invalidColors: return "Use five six-digit hex colors per theme."
    case .invalidBlock: return "Invalid content block."
    case .invalidTopic: return "Invalid topic."
    case .tooLarge: return "Appearance file is too large."
    }
  }
}

/// A shortcut of the topics block: it starts a conversation in `category`, a conversation
/// category key of the project.
@objc(CLFAppearanceTopic) public final class AppearanceTopic: NSObject {
  @objc public let label: String
  @objc public let category: String
  /// An emoji or short text of up to 32 characters, or a PNG/JPEG data URL; empty for none.
  @objc public let icon: String
  @objc public init(label: String, category: String, icon: String = "") {
    self.label = label
    self.category = category
    self.icon = icon
  }
}

/// A checked theme for `Cluefolk.setAppearance(_:)`, made by `AppearanceBuilder`.
@objc(CLFAppearance) public final class Appearance: NSObject {
  /// The theme as the widget receives it; `rotation` is always present.
  let json: [String: Any]
  let rotation: AppearanceRotation
  fileprivate init(json: [String: Any], rotation: AppearanceRotation) {
    self.json = json
    self.rotation = rotation
  }
}

/// The theme of the support screen: the default one or the file downloaded from
/// Settings → Widget → Download for build, changed in code if needed. Setters replace the
/// block of their type or add it in the order welcome, topics, contact; `build()` checks
/// the result.
@objc(CLFAppearanceBuilder) public final class AppearanceBuilder: NSObject {
  static let paletteKeys = ["accent", "action", "background", "surface", "text"]
  private static let blockTypes = ["welcome", "topics", "contact"]
  private static let maxJSONLength = 1_500_000
  private var value: [String: Any]

  /// Bounds both representations before Foundation allocates a parsed object graph.
  private static func boundedJSONData(_ json: String) throws -> Data {
    guard json.utf16.count <= maxJSONLength else { throw AppearanceError.tooLarge }
    let data = Data(json.utf8)
    guard data.count <= maxJSONLength else { throw AppearanceError.tooLarge }
    return data
  }

  /// Starts from the default theme.
  @objc public override init() {
    value = (try? JSONSerialization.jsonObject(with: Data(AppearanceDefaults.json.utf8))) as? [String: Any] ?? [:]
  }

  /// Starts from a theme file (appearance v2). Throws `AppearanceError.invalidJSON` for text
  /// that is not a JSON object, a version other than 2 or a key the theme does not have.
  @objc(initWithJSON:error:) public init(json: String) throws {
    let data = try Self.boundedJSONData(json)
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let theme = object as? [String: Any], theme["version"] as? Int == 2, Self.knownKeys(theme)
    else { throw AppearanceError.invalidJSON }
    value = theme
  }

  /// The heading of the support screen: 1 to 100 characters.
  @discardableResult @objc public func title(_ title: String) -> AppearanceBuilder {
    value["title"] = title
    return self
  }
  @discardableResult @objc public func mode(_ mode: AppearanceMode) -> AppearanceBuilder {
    switch mode {
    case .system: value["mode"] = "system"
    case .light: value["mode"] = "light"
    case .dark: value["mode"] = "dark"
    }
    return self
  }
  @discardableResult @objc public func rotation(_ rotation: AppearanceRotation) -> AppearanceBuilder {
    value["rotation"] = rotation == .free ? "free" : "game"
    return self
  }
  /// The five base colors of the light theme, each as #RRGGBB.
  @discardableResult @objc public func lightColors(
    accent: String, action: String, background: String, surface: String, text: String
  ) -> AppearanceBuilder {
    palette("light", [accent, action, background, surface, text])
  }
  /// The five base colors of the dark theme, each as #RRGGBB.
  @discardableResult @objc public func darkColors(
    accent: String, action: String, background: String, surface: String, text: String
  ) -> AppearanceBuilder {
    palette("dark", [accent, action, background, surface, text])
  }
  /// The greeting: a title of up to 100 and a text of up to 1000 characters.
  @discardableResult @objc public func welcome(title: String, text: String) -> AppearanceBuilder {
    block("welcome", title: title, text: text, items: [])
  }
  /// Up to 12 shortcuts under a title of up to 100 characters.
  @discardableResult @objc public func topics(title: String, items: [AppearanceTopic]) -> AppearanceBuilder {
    block(
      "topics", title: title, text: "",
      items: items.map { ["label": $0.label, "icon": $0.icon, "category": $0.category] })
  }
  /// The button that starts a conversation: a title of up to 100 and a text of up to 1000 characters.
  @discardableResult @objc public func contact(title: String, text: String) -> AppearanceBuilder {
    block("contact", title: title, text: text, items: [])
  }

  /// Checks the theme as the widget does. The result always names its rotation.
  @objc(build:) public func build() throws -> Appearance {
    try Self.validate(value)
    var theme = value
    let rotation: AppearanceRotation = theme["rotation"] as? String == "free" ? .free : .game
    theme["rotation"] = rotation == .free ? "free" : "game"
    guard let data = try? JSONSerialization.data(withJSONObject: theme, options: [.withoutEscapingSlashes])
    else { throw AppearanceError.invalidJSON }
    guard String(decoding: data, as: UTF8.self).utf16.count <= 1_500_000 else { throw AppearanceError.tooLarge }
    return Appearance(json: theme, rotation: rotation)
  }

  /// For engine wrappers (the Unity package): applies changes given as a JSON object whose keys
  /// are all optional — `title`, `mode`, `rotation`, `colors` (`light`/`dark` with any of the five
  /// colors), `welcome` and `contact` (`title`, `text`), `topics` (`title`, `items` of `label`,
  /// `category`, `icon`). What is left out keeps its current value; null counts as left out.
  /// An empty string changes nothing. Throws `AppearanceError.invalidJSON` and changes nothing
  /// when the object has another shape; the values themselves are checked by `build()`.
  @discardableResult @objc(applyOverridesJSON:error:)
  public func applyOverrides(_ json: String) throws -> AppearanceBuilder {
    if json.isEmpty { return self }
    let saved = value
    do {
      let data = try Self.boundedJSONData(json)
      guard let object = try? JSONSerialization.jsonObject(with: data),
        let changes = try Self.object(
          object, ["title", "mode", "rotation", "colors", "welcome", "topics", "contact"])
      else { throw AppearanceError.invalidJSON }
      if let title = try Self.string(changes, "title") { self.title(title) }
      if let name = try Self.string(changes, "mode") {
        guard let index = ["system", "light", "dark"].firstIndex(of: name), let mode = AppearanceMode(rawValue: index)
        else { throw AppearanceError.invalidJSON }
        self.mode(mode)
      }
      if let name = try Self.string(changes, "rotation") {
        guard name == "game" || name == "free" else { throw AppearanceError.invalidJSON }
        rotation(name == "free" ? .free : .game)
      }
      if let colors = try Self.object(changes["colors"], ["light", "dark"]) {
        for theme in ["light", "dark"] {
          guard let given = try Self.object(colors[theme], Set(Self.paletteKeys)) else { continue }
          let current = (value["colors"] as? [String: Any])?[theme] as? [String: Any] ?? [:]
          let merged = try Self.paletteKeys.map { try Self.string(given, $0) ?? current[$0] as? String ?? "" }
          palette(theme, merged)
        }
      }
      for type in Self.blockTypes {
        let keys: Set<String> = type == "topics" ? ["title", "items"] : ["title", "text"]
        guard let given = try Self.object(changes[type], keys) else { continue }
        let current = currentBlock(type)
        var items = current?["items"] as? [Any] ?? []
        if let raw = given["items"], !(raw is NSNull) {
          guard let list = raw as? [Any] else { throw AppearanceError.invalidJSON }
          items = try list.map { entry -> Any in
            guard let item = try Self.object(entry, ["label", "category", "icon"]) else { throw AppearanceError.invalidJSON }
            return [
              "label": try Self.string(item, "label") ?? "", "icon": try Self.string(item, "icon") ?? "",
              "category": try Self.string(item, "category") ?? "",
            ]
          }
        }
        block(
          type, title: try Self.string(given, "title") ?? current?["title"] as? String ?? "",
          text: try Self.string(given, "text") ?? current?["text"] as? String ?? "", items: items)
      }
    } catch {
      value = saved
      throw error
    }
    return self
  }

  @discardableResult private func palette(_ theme: String, _ colors: [String]) -> AppearanceBuilder {
    var all = value["colors"] as? [String: Any] ?? [:]
    all[theme] = Dictionary(uniqueKeysWithValues: zip(Self.paletteKeys, colors))
    value["colors"] = all
    return self
  }
  private func currentBlock(_ type: String) -> [String: Any]? {
    (value["blocks"] as? [Any])?.lazy.compactMap { $0 as? [String: Any] }.first { $0["type"] as? String == type }
  }
  /// Replaces the block of this type, or inserts it before the first block that comes later in
  /// the order welcome, topics, contact.
  @discardableResult private func block(_ type: String, title: String, text: String, items: [Any]) -> AppearanceBuilder {
    let entry: [String: Any] = ["type": type, "title": title, "text": text, "items": items]
    var blocks = value["blocks"] as? [Any] ?? []
    let typeOf = { (block: Any) in (block as? [String: Any])?["type"] as? String }
    if let index = blocks.firstIndex(where: { typeOf($0) == type }) {
      blocks[index] = entry
    } else {
      let rank = Self.blockTypes.firstIndex(of: type) ?? Self.blockTypes.count
      let later = blocks.firstIndex { block in
        typeOf(block).flatMap { Self.blockTypes.firstIndex(of: $0) }.map { $0 > rank } ?? false
      }
      blocks.insert(entry, at: later ?? blocks.endIndex)
    }
    value["blocks"] = blocks
    return self
  }

  /// Only the keys of appearance v2, at every level.
  private static func knownKeys(_ theme: [String: Any]) -> Bool {
    func only(_ value: Any?, _ keys: Set<String>) -> Bool {
      (value as? [String: Any]).map { Set($0.keys).isSubset(of: keys) } ?? true
    }
    let colors = theme["colors"] as? [String: Any]
    guard only(theme, ["version", "title", "mode", "rotation", "colors", "blocks"]),
      only(colors, ["light", "dark"]), only(colors?["light"], Set(paletteKeys)),
      only(colors?["dark"], Set(paletteKeys))
    else { return false }
    for block in theme["blocks"] as? [Any] ?? [] {
      guard only(block, ["type", "title", "text", "items"]) else { return false }
      for item in (block as? [String: Any])?["items"] as? [Any] ?? [] where !only(item, ["label", "icon", "category"]) {
        return false
      }
    }
    return true
  }
  /// Reads only bounded PNG/JPEG metadata. This rejects compressed images whose
  /// small data URL would expand into an unsafe WebView raster.
  private static func validEmbeddedImage(_ value: String) -> Bool {
    guard value.utf16.count <= 700_040, let comma = value.firstIndex(of: ",") else { return false }
    let prefix = String(value[..<comma])
    guard prefix == "data:image/png;base64" || prefix == "data:image/jpeg;base64",
      let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
      !data.isEmpty, data.count <= 525_000
    else { return false }
    let bytes = [UInt8](data)
    func byte(_ offset: Int) -> Int { bytes.indices.contains(offset) ? Int(bytes[offset]) : -1 }
    func uint16(_ offset: Int) -> Int { byte(offset) << 8 | byte(offset + 1) }
    func uint32(_ offset: Int) -> Int {
      byte(offset) << 24 | byte(offset + 1) << 16 | byte(offset + 2) << 8 | byte(offset + 3)
    }
    var width = 0
    var height = 0
    if prefix == "data:image/png;base64", bytes.count >= 24,
      Array(bytes.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      uint32(8) == 13,
      Array(bytes[12..<16]) == [0x49, 0x48, 0x44, 0x52]
    {
      width = uint32(16)
      height = uint32(20)
    } else if prefix == "data:image/jpeg;base64", byte(0) == 0xff, byte(1) == 0xd8 {
      var offset = 2
      while offset + 1 < bytes.count {
        guard byte(offset) == 0xff else { break }
        offset += 1
        while byte(offset) == 0xff { offset += 1 }
        let marker = byte(offset)
        offset += 1
        if marker == 0xda || marker == 0xd9 || marker < 0 { break }
        if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
        if offset + 2 > bytes.count { break }
        let length = uint16(offset)
        if length < 2 || offset + length > bytes.count { break }
        if (0xc0...0xcf).contains(marker), ![0xc4, 0xc8, 0xcc].contains(marker), length >= 8 {
          height = uint16(offset + 3)
          width = uint16(offset + 5)
          break
        }
        offset += length
      }
    }
    return width >= 1 && height >= 1 && width <= 2048 && height <= 2048 && width * height <= 4_194_304
  }
  /// The checks of the widget's parseAppearance.
  private static func validate(_ theme: [String: Any]) throws {
    guard theme["version"] as? Int == 2, let mode = theme["mode"] as? String, ["system", "light", "dark"].contains(mode),
      theme["rotation"].map({ ["game", "free"].contains($0 as? String ?? "") }) ?? true
    else { throw AppearanceError.invalidJSON }
    guard let title = theme["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      title.utf16.count <= 100
    else { throw AppearanceError.invalidTitle }
    let colors = theme["colors"] as? [String: Any]
    for theme in ["light", "dark"] {
      guard let palette = colors?[theme] as? [String: Any], palette.count == paletteKeys.count,
        paletteKeys.allSatisfy({ matches(palette[$0], "^#[0-9A-Fa-f]{6}\\z") })
      else { throw AppearanceError.invalidColors }
    }
    guard let blocks = theme["blocks"] as? [Any], blocks.count <= 4 else { throw AppearanceError.invalidBlock }
    var seen: Set<String> = []
    for entry in blocks {
      guard let block = entry as? [String: Any], let type = block["type"] as? String, blockTypes.contains(type),
        seen.insert(type).inserted, let title = block["title"] as? String, title.utf16.count <= 100,
        let text = block["text"] as? String, text.utf16.count <= 1000, let items = block["items"] as? [Any],
        items.count <= 12, type == "topics" || items.isEmpty
      else { throw AppearanceError.invalidBlock }
      for entry in items {
        guard let item = entry as? [String: Any], let label = item["label"] as? String,
          !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf16.count <= 80,
          matches(item["category"], "^[a-z][a-z0-9_]{0,49}\\z"), let icon = item["icon"] as? String,
          icon.hasPrefix("data:")
            ? validEmbeddedImage(icon)
            : icon.utf16.count <= 32 && !icon.contains("<") && !icon.contains(">")
        else { throw AppearanceError.invalidTopic }
      }
    }
  }
  /// The pattern matches the whole string; `\z`, unlike `$`, also refuses a trailing line break.
  private static func matches(_ value: Any?, _ pattern: String) -> Bool {
    (value as? String)?.range(of: pattern, options: .regularExpression) != nil
  }
  /// An object with only these keys; nil when missing or null.
  private static func object(_ value: Any?, _ keys: Set<String>) throws -> [String: Any]? {
    guard let value, !(value is NSNull) else { return nil }
    guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
      throw AppearanceError.invalidJSON
    }
    return object
  }
  /// A string value; nil when missing or null.
  private static func string(_ object: [String: Any], _ key: String) throws -> String? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let text = value as? String else { throw AppearanceError.invalidJSON }
    return text
  }
}
