import UIKit
import XCTest

@testable import Cluefolk

/// The theme comes from the file of Settings → Widget → Download for build or from code, and is
/// checked like the widget's parseAppearance does.
final class AppearanceBuilderTests: XCTestCase {
  private let none: [Any] = []
  private func defaults() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AppearanceDefaults.json.utf8)) as? [String: Any])
  }
  /// The default theme as a file, changed by `change`.
  private func file(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> String {
    var value = try defaults()
    change(&value)
    return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
  }
  private func built(_ change: (inout [String: Any]) -> Void) throws -> Appearance {
    try AppearanceBuilder(json: file(change)).build()
  }
  private func blocks(_ appearance: Appearance) -> [[String: Any]] {
    appearance.json["blocks"] as? [[String: Any]] ?? []
  }
  private func types(_ appearance: Appearance) -> [String] {
    blocks(appearance).map { $0["type"] as? String ?? "" }
  }
  private func block(_ appearance: Appearance, _ type: String) -> [String: Any]? {
    blocks(appearance).first { $0["type"] as? String == type }
  }
  private func topic(label: String = "Account", category: String = "account", icon: String = "") -> [String: Any] {
    ["label": label, "category": category, "icon": icon]
  }
  /// Replaces the items of the topics block.
  private func items(_ items: [Any]) -> (inout [String: Any]) -> Void {
    { value in
      value["blocks"] = (value["blocks"] as? [[String: Any]] ?? []).map { block in
        guard block["type"] as? String == "topics" else { return block }
        return block.merging(["items": items]) { $1 }
      }
    }
  }
  private func assertError<T>(
    _ expected: AppearanceError, _ body: @autoclosure () throws -> T, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try body(), message, file: file, line: line) {
      XCTAssertEqual($0 as? AppearanceError, expected, message, file: file, line: line)
    }
  }

  func testDefaultBuildIsTheDefaultTheme() throws {
    let appearance = try AppearanceBuilder().build()
    XCTAssertEqual(appearance.json as NSDictionary, try defaults() as NSDictionary)
    XCTAssertEqual(appearance.rotation, .game)
  }

  func testFileRoundTrip() throws {
    let custom: [String: Any] = [
      "version": 2, "title": "Help desk", "mode": "dark", "rotation": "free",
      "colors": [
        "light": ["accent": "#000000", "action": "#111111", "background": "#FFFFFF", "surface": "#eeeeee", "text": "#222222"],
        "dark": ["accent": "#AbCdEf", "action": "#123456", "background": "#000000", "surface": "#101010", "text": "#fafafa"],
      ],
      "blocks": [
        ["type": "contact", "title": "", "text": "We answer within a day.", "items": none],
        [
          "type": "topics", "title": "Topics", "text": "",
          "items": [topic(icon: "data:image/png;base64,iVBORw0KGgo="), topic(label: "Bugs", category: "bug_2", icon: "🐞")],
        ],
      ],
    ]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: custom), as: UTF8.self)
    let appearance = try AppearanceBuilder(json: json).build()
    XCTAssertEqual(appearance.json as NSDictionary, custom as NSDictionary)
    XCTAssertEqual(appearance.rotation, .free)
    // A file without rotation turns like the game, and the result says so.
    let unnamed = try built { $0.removeValue(forKey: "rotation") }
    XCTAssertEqual(unnamed.rotation, .game)
    XCTAssertEqual(unnamed.json as NSDictionary, try defaults() as NSDictionary)
  }

  func testFileThatIsNotATheme() throws {
    for json in ["", "not json", "[]", "[{}]", "{\"version\":2", "{}"] {
      assertError(.invalidJSON, try AppearanceBuilder(json: json))
    }
    assertError(.invalidJSON, try AppearanceBuilder(json: file { $0["version"] = 1 }))
    assertError(.invalidJSON, try AppearanceBuilder(json: file { $0["version"] = "2" }))
    assertError(.invalidJSON, try AppearanceBuilder(json: file { $0["version"] = 2.5 }))
    assertError(.invalidJSON, try AppearanceBuilder(json: file { $0.removeValue(forKey: "version") }))
  }

  func testFileWithKeysOutsideTheSchema() throws {
    assertError(.invalidJSON, try AppearanceBuilder(json: file { $0["logo"] = "data:image/png;base64,AA==" }))
    assertError(.invalidJSON, try AppearanceBuilder(json: file { $0["colors"] = ["light": [String: String](), "dark": [String: String](), "sepia": [String: String]()] }))
    assertError(.invalidJSON, try AppearanceBuilder(json: file {
      var colors = $0["colors"] as? [String: [String: String]] ?? [:]
      colors["light"]?["muted"] = "#000000"
      $0["colors"] = colors
    }))
    assertError(.invalidJSON, try AppearanceBuilder(json: file {
      $0["blocks"] = [["type": "welcome", "title": "", "text": "", "items": none, "image": ""]]
    }))
    assertError(.invalidJSON, try AppearanceBuilder(json: file(items([topic().merging(["url": "x"]) { $1 }]))))
  }

  func testSetters() throws {
    let appearance = try AppearanceBuilder()
      .title("Help desk")
      .mode(.dark)
      .rotation(.free)
      .lightColors(accent: "#000001", action: "#000002", background: "#000003", surface: "#000004", text: "#000005")
      .darkColors(accent: "#100001", action: "#100002", background: "#100003", surface: "#100004", text: "#100005")
      .welcome(title: "Hi", text: "Ask us anything.")
      .topics(title: "Pick one", items: [
        AppearanceTopic(label: "Bugs", category: "bug", icon: "🐞"), AppearanceTopic(label: "Billing", category: "billing"),
      ])
      .contact(title: "Write to us", text: "Any time.")
      .build()
    XCTAssertEqual(appearance.json["title"] as? String, "Help desk")
    XCTAssertEqual(appearance.json["mode"] as? String, "dark")
    XCTAssertEqual(appearance.json["rotation"] as? String, "free")
    XCTAssertEqual(appearance.rotation, .free)
    let colors = try XCTUnwrap(appearance.json["colors"] as? [String: [String: String]])
    XCTAssertEqual(colors["light"], ["accent": "#000001", "action": "#000002", "background": "#000003", "surface": "#000004", "text": "#000005"])
    XCTAssertEqual(colors["dark"], ["accent": "#100001", "action": "#100002", "background": "#100003", "surface": "#100004", "text": "#100005"])
    XCTAssertEqual(blocks(appearance) as NSArray, [
      ["type": "welcome", "title": "Hi", "text": "Ask us anything.", "items": none],
      [
        "type": "topics", "title": "Pick one", "text": "",
        "items": [topic(label: "Bugs", category: "bug", icon: "🐞"), topic(label: "Billing", category: "billing")],
      ],
      ["type": "contact", "title": "Write to us", "text": "Any time.", "items": none],
    ] as NSArray)
    XCTAssertEqual(try AppearanceBuilder().mode(.light).build().json["mode"] as? String, "light")
    XCTAssertEqual(try AppearanceBuilder().mode(.dark).mode(.system).build().json["mode"] as? String, "system")
    let game = try AppearanceBuilder().rotation(.free).rotation(.game).build()
    XCTAssertEqual(game.json["rotation"] as? String, "game")
    XCTAssertEqual(game.rotation, .game)
    // A setter changes only its part of a file.
    let changed = try AppearanceBuilder(json: file()).darkColors(
      accent: "#000000", action: "#000000", background: "#000000", surface: "#000000", text: "#ffffff"
    ).build()
    var expected = try defaults()
    expected["colors"] = [
      "light": (expected["colors"] as? [String: Any])?["light"] ?? [:],
      "dark": ["accent": "#000000", "action": "#000000", "background": "#000000", "surface": "#000000", "text": "#ffffff"],
    ]
    XCTAssertEqual(changed.json as NSDictionary, expected as NSDictionary)
  }

  func testBlocksAreReplacedInPlaceOrInsertedInOrder() throws {
    let empty = try AppearanceBuilder(json: file { $0["blocks"] = self.none })
    XCTAssertEqual(types(try empty.build()), [])
    empty.contact(title: "C", text: "")
    empty.welcome(title: "W", text: "")
    empty.topics(title: "T", items: [])
    XCTAssertEqual(types(try empty.build()), ["welcome", "topics", "contact"])
    // The team's order is kept; a new block goes before the first one that comes later.
    let custom = try AppearanceBuilder(json: file {
      $0["blocks"] = [
        ["type": "contact", "title": "C", "text": "", "items": none], ["type": "welcome", "title": "W", "text": "", "items": none],
      ]
    })
    custom.welcome(title: "Hello", text: "Text")
    XCTAssertEqual(types(try custom.build()), ["contact", "welcome"])
    XCTAssertEqual(block(try custom.build(), "welcome")?["title"] as? String, "Hello")
    custom.topics(title: "T", items: [])
    XCTAssertEqual(types(try custom.build()), ["topics", "contact", "welcome"])
    let welcomeOnly = try AppearanceBuilder(json: file { $0["blocks"] = [["type": "welcome", "title": "", "text": "", "items": none]] })
    welcomeOnly.contact(title: "C", text: "")
    welcomeOnly.topics(title: "T", items: [])
    XCTAssertEqual(types(try welcomeOnly.build()), ["welcome", "topics", "contact"])
  }

  func testTitleRules() throws {
    for title in ["", "   ", "\n\t", String(repeating: "a", count: 101), String(repeating: "👤", count: 51)] {
      assertError(.invalidTitle, try AppearanceBuilder().title(title).build())
    }
    // Up to 100 UTF-16 code units, as the widget counts.
    XCTAssertNoThrow(try AppearanceBuilder().title(String(repeating: "a", count: 100)).build())
    XCTAssertNoThrow(try AppearanceBuilder().title(String(repeating: "👤", count: 50)).build())
    assertError(.invalidTitle, try built { $0["title"] = 5 })
    assertError(.invalidTitle, try built { $0.removeValue(forKey: "title") })
  }

  func testModeAndRotationFromAFile() throws {
    assertError(.invalidJSON, try built { $0["mode"] = "sepia" })
    assertError(.invalidJSON, try built { $0.removeValue(forKey: "mode") })
    assertError(.invalidJSON, try built { $0["rotation"] = "sideways" })
    assertError(.invalidJSON, try built { $0["rotation"] = NSNull() })
    XCTAssertEqual(try built { $0["rotation"] = "free" }.rotation, .free)
  }

  func testColorRules() throws {
    for color in ["#12345", "#1234567", "red", "#12345g", "123456", "#123456\n", " #123456", ""] {
      assertError(.invalidColors, try AppearanceBuilder()
        .lightColors(accent: color, action: "#000000", background: "#000000", surface: "#000000", text: "#000000").build())
      assertError(.invalidColors, try AppearanceBuilder()
        .darkColors(accent: "#000000", action: "#000000", background: "#000000", surface: "#000000", text: color).build())
    }
    XCTAssertNoThrow(try AppearanceBuilder()
      .lightColors(accent: "#ABCdef", action: "#000000", background: "#FFFFFF", surface: "#a1B2c3", text: "#999999").build())
    assertError(.invalidColors, try built {
      var colors = $0["colors"] as? [String: [String: String]] ?? [:]
      colors["dark"]?.removeValue(forKey: "text")
      $0["colors"] = colors
    })
    assertError(.invalidColors, try built { $0["colors"] = ["light": (($0["colors"] as? [String: Any])?["light"]) ?? [String: String]()] })
    assertError(.invalidColors, try built { $0["colors"] = "#000000" })
  }

  func testBlockRules() throws {
    let welcome: [String: Any] = ["type": "welcome", "title": "", "text": "", "items": none]
    let topics: [String: Any] = ["type": "topics", "title": "", "text": "", "items": none]
    let contact: [String: Any] = ["type": "contact", "title": "", "text": "", "items": none]
    assertError(.invalidBlock, try built { $0["blocks"] = [welcome, topics, contact, welcome, topics] })
    assertError(.invalidBlock, try built { $0["blocks"] = [welcome, welcome] })
    assertError(.invalidBlock, try built { $0["blocks"] = [welcome.merging(["type": "faq"]) { $1 }] })
    assertError(.invalidBlock, try built { $0["blocks"] = [welcome.merging(["items": [self.topic()]]) { $1 }] })
    assertError(.invalidBlock, try built { $0["blocks"] = [contact.merging(["text": 5]) { $1 }] })
    assertError(.invalidBlock, try built { $0["blocks"] = ["welcome"] })
    assertError(.invalidBlock, try built { $0["blocks"] = welcome })
    assertError(.invalidBlock, try AppearanceBuilder().welcome(title: String(repeating: "a", count: 101), text: "").build())
    assertError(.invalidBlock, try AppearanceBuilder().contact(title: "", text: String(repeating: "a", count: 1001)).build())
    XCTAssertNoThrow(try AppearanceBuilder()
      .welcome(title: String(repeating: "a", count: 100), text: String(repeating: "a", count: 1000)).build())
    let twelve = (0..<12).map { AppearanceTopic(label: "Topic \($0)", category: "account") }
    XCTAssertNoThrow(try AppearanceBuilder().topics(title: "", items: twelve).build())
    assertError(.invalidBlock, try AppearanceBuilder()
      .topics(title: "", items: twelve + [AppearanceTopic(label: "One more", category: "account")]).build())
  }

  func testTopicRules() throws {
    let rejected = [
      topic(label: ""), topic(label: "  "), topic(label: String(repeating: "a", count: 81)),
      topic(category: "Account"), topic(category: "1account"), topic(category: "my-account"), topic(category: ""),
      topic(category: "account\n"), topic(category: "a" + String(repeating: "b", count: 50)),
      topic(icon: String(repeating: "a", count: 33)), topic(icon: "<b>"), topic(icon: "a>b"),
      topic(icon: "data:image/gif;base64,R0lGOD=="), topic(icon: "data:image/png;base64,"),
      topic(icon: "data:image/png;base64,AA==AA"), topic(icon: "data:text/html,<b>"),
      topic(icon: "data:image/png;base64," + String(repeating: "A", count: 700_040 - 21)),
    ]
    for item in rejected {
      assertError(.invalidTopic, try built(items([item])), "\(item)")
    }
    assertError(.invalidTopic, try built(items([["label": "L", "category": "account"]])))
    assertError(.invalidTopic, try built(items(["account"])))
    assertError(.invalidTopic, try AppearanceBuilder().topics(title: "", items: [AppearanceTopic(label: " ", category: "account")]).build())
    let accepted = [
      topic(label: String(repeating: "a", count: 80)), topic(category: "a" + String(repeating: "_", count: 49)),
      topic(category: "a1_b"), topic(icon: String(repeating: "a", count: 32)), topic(icon: "👤"), topic(icon: ""),
      topic(icon: "data:image/png;base64,AA=="), topic(icon: "data:image/jpeg;base64,/9j/4AAQ"),
      topic(icon: "data:image/png;base64," + String(repeating: "A", count: 700_040 - 22)),
    ]
    for item in accepted {
      XCTAssertNoThrow(try built(items([item])), "\(item)")
    }
  }

  /// Up to 1.5 MB as the widget measures it (the length of the compact JSON).
  func testTooLarge() throws {
    let image = "data:image/png;base64," + String(repeating: "A", count: 520_000)
    XCTAssertNoThrow(try built(items([topic(icon: image), topic(icon: image)])))
    assertError(.tooLarge, try built(items([topic(icon: image), topic(icon: image), topic(icon: image)])))
  }

  func testErrorsReachObjectiveC() {
    let error = AppearanceError.invalidColors as NSError
    XCTAssertEqual(error.domain, "Cluefolk.AppearanceError")
    XCTAssertEqual(error.code, 3)
    XCTAssertEqual(error.localizedDescription, "Use five six-digit hex colors per theme.")
  }

  // MARK: Overrides of engine wrappers

  func testOverrides() throws {
    let overrides = """
      {"title":"Help desk","mode":"light","rotation":"free",
       "colors":{"light":{"accent":"#000001","action":"#000002","background":"#000003","surface":"#000004","text":"#000005"},
                 "dark":{"accent":"#100001"}},
       "welcome":{"title":"Hi","text":"Ask us."},
       "topics":{"title":"Pick","items":[{"label":"Bugs","category":"bug","icon":"🐞"},{"label":"Billing","category":"billing"}]},
       "contact":{"title":"Write"}}
      """
    let appearance = try AppearanceBuilder().applyOverrides(overrides).build()
    XCTAssertEqual(appearance.json["title"] as? String, "Help desk")
    XCTAssertEqual(appearance.json["mode"] as? String, "light")
    XCTAssertEqual(appearance.rotation, .free)
    let colors = try XCTUnwrap(appearance.json["colors"] as? [String: [String: String]])
    XCTAssertEqual(colors["light"], ["accent": "#000001", "action": "#000002", "background": "#000003", "surface": "#000004", "text": "#000005"])
    // Colors left out keep their current value.
    let defaultDark = try XCTUnwrap((try defaults()["colors"] as? [String: [String: String]])?["dark"])
    XCTAssertEqual(colors["dark"], defaultDark.merging(["accent": "#100001"]) { $1 })
    XCTAssertEqual(blocks(appearance) as NSArray, [
      ["type": "welcome", "title": "Hi", "text": "Ask us.", "items": none],
      [
        "type": "topics", "title": "Pick", "text": "",
        "items": [topic(label: "Bugs", category: "bug", icon: "🐞"), topic(label: "Billing", category: "billing")],
      ],
      ["type": "contact", "title": "Write", "text": "", "items": none],
    ] as NSArray)
  }

  func testOverridesKeepWhatIsLeftOut() throws {
    let base = try AppearanceBuilder().build()
    XCTAssertEqual(try AppearanceBuilder().applyOverrides("").build().json as NSDictionary, base.json as NSDictionary)
    XCTAssertEqual(try AppearanceBuilder().applyOverrides("{}").build().json as NSDictionary, base.json as NSDictionary)
    XCTAssertEqual(
      try AppearanceBuilder().applyOverrides(#"{"title":null,"colors":{"light":null},"welcome":null}"#).build().json as NSDictionary,
      base.json as NSDictionary)
    let renamed = try AppearanceBuilder().applyOverrides(#"{"topics":{"title":"Renamed"}}"#).build()
    XCTAssertEqual(block(renamed, "topics")?["title"] as? String, "Renamed")
    XCTAssertEqual(block(renamed, "topics")?["items"] as? NSArray, block(base, "topics")?["items"] as? NSArray)
    let replaced = try AppearanceBuilder().applyOverrides(#"{"topics":{"items":[{"label":"Bugs","category":"bug"}]}}"#).build()
    XCTAssertEqual(block(replaced, "topics")?["title"] as? String, block(base, "topics")?["title"] as? String)
    XCTAssertEqual(block(replaced, "topics")?["items"] as? NSArray, [topic(label: "Bugs", category: "bug")] as NSArray)
    let text = try AppearanceBuilder().applyOverrides(#"{"welcome":{"text":"New text"}}"#).build()
    XCTAssertEqual(block(text, "welcome")?["title"] as? String, block(base, "welcome")?["title"] as? String)
    XCTAssertEqual(block(text, "welcome")?["text"] as? String, "New text")
    // A block the file does not have is added in order.
    let contactOnly = try AppearanceBuilder(json: file { $0["blocks"] = [["type": "contact", "title": "C", "text": "", "items": none]] })
    let added = try contactOnly.applyOverrides(#"{"welcome":{"title":"W"},"topics":{"title":"T"}}"#).build()
    XCTAssertEqual(types(added), ["welcome", "topics", "contact"])
    XCTAssertEqual(block(added, "welcome")?["text"] as? String, "")
    XCTAssertEqual(block(added, "topics")?["items"] as? NSArray, [] as NSArray)
  }

  func testOverridesOfAnotherShapeChangeNothing() throws {
    let rejected = [
      "nope", "[]", "\"title\"", #"{"logo":"x"}"#, #"{"title":5}"#, #"{"title":"New","mode":"sepia"}"#,
      #"{"mode":"Dark"}"#, #"{"rotation":"sideways"}"#, #"{"rotation":true}"#, ##"{"colors":"#000000"}"##,
      #"{"colors":{"sepia":{}}}"#, ##"{"colors":{"light":{"muted":"#000000"}}}"##, #"{"colors":{"light":{"accent":0}}}"#,
      #"{"welcome":"Hi"}"#, #"{"welcome":{"items":[]}}"#, #"{"contact":{"title":"C","label":"x"}}"#,
      #"{"topics":{"text":"x"}}"#, #"{"topics":{"items":"x"}}"#, #"{"topics":{"items":[5]}}"#,
      #"{"topics":{"items":[{"label":"L","category":"c","url":"x"}]}}"#, #"{"topics":{"items":[{"label":1,"category":"c"}]}}"#,
    ]
    let base = try AppearanceBuilder().build()
    for overrides in rejected {
      let builder = AppearanceBuilder()
      assertError(.invalidJSON, try builder.applyOverrides(overrides), overrides)
      XCTAssertEqual(try builder.build().json as NSDictionary, base.json as NSDictionary, overrides)
    }
  }

  /// Values are checked when the theme is built, like those of the setters.
  func testOverriddenValuesAreCheckedByBuild() throws {
    assertError(.invalidColors, try AppearanceBuilder().applyOverrides(#"{"colors":{"light":{"accent":"red"}}}"#).build())
    assertError(.invalidTitle, try AppearanceBuilder().applyOverrides(#"{"title":" "}"#).build())
    assertError(.invalidTopic, try AppearanceBuilder().applyOverrides(#"{"topics":{"items":[{"label":"L"}]}}"#).build())
    assertError(.invalidTopic, try AppearanceBuilder().applyOverrides(#"{"topics":{"items":[{"category":"bug"}]}}"#).build())
  }

  // MARK: The SDK

  /// rotation free: support turns to everything the app allows, whatever the game supports.
  @MainActor func testThemeRotationSelectsTheMask() throws {
    let sdk = Cluefolk()
    let mask = { SupportController.orientations(app: .allButUpsideDown, game: .landscape, now: .landscapeLeft, free: sdk.freeRotation) }
    XCTAssertFalse(sdk.freeRotation)
    XCTAssertEqual(mask().mask, .landscape)
    sdk.setAppearance(try AppearanceBuilder().rotation(.free).build())
    XCTAssertTrue(sdk.freeRotation)
    XCTAssertEqual(mask().mask, .allButUpsideDown)
    XCTAssertEqual(mask().current, .landscapeLeft)
    sdk.setAppearance(try AppearanceBuilder().build())
    XCTAssertFalse(sdk.freeRotation)
    XCTAssertEqual(mask().mask, .landscape)
    sdk.setAppearance(try built { $0["rotation"] = "free" })
    XCTAssertEqual(mask().mask, .allButUpsideDown)
    sdk.setAppearance(nil)
    XCTAssertFalse(sdk.freeRotation)
    XCTAssertEqual(mask().mask, .landscape)
  }

  @MainActor func testBootstrapCarriesTheTheme() throws {
    let sdk = Cluefolk()
    let session = StoredSession(
      token: "t", expiresAt: Date(), playerId: "p", kind: "anonymous", externalUserId: nil, claimedExternalId: "")
    let payload = { sdk.bootstrapPayload(code: "c", apiURL: URL(string: "https://cluefolk.example")!, session: session) }
    XCTAssertNil(payload()["appearance"])
    let appearance = try AppearanceBuilder().title("Help desk").build()
    sdk.setAppearance(appearance)
    XCTAssertEqual(payload()["appearance"] as? NSDictionary, appearance.json as NSDictionary)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(payload()))
    sdk.setAppearance(nil)
    XCTAssertNil(payload()["appearance"])
  }
}
