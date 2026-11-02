import UIKit
import XCTest

@testable import Cluefolk

/// Support turns the way the game does: landscape, portrait or both; with free rotation
/// it turns to everything the app allows.
final class SupportOrientationTests: XCTestCase {
  private final class Game: UIViewController {
    let mask: UIInterfaceOrientationMask
    init(_ mask: UIInterfaceOrientationMask) {
      self.mask = mask
      super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { mask }
  }

  @MainActor func testLandscapeGameGetsLandscapeSupport() {
    let game = SupportController.orientations(of: Game(.landscape))
    XCTAssertEqual(game.mask, .landscape)
    XCTAssertEqual(game.current, .landscapeRight)
    let support = SupportController(
      sdk: Cluefolk.shared, apiURL: URL(string: "https://cluefolk.com")!, game: game)
    XCTAssertEqual(support.supportedInterfaceOrientations, .landscape)
    XCTAssertEqual(support.preferredInterfaceOrientationForPresentation, .landscapeRight)
  }

  @MainActor func testPortraitGameGetsPortraitSupport() {
    let game = SupportController.orientations(of: Game(.portrait))
    XCTAssertEqual(game.mask, .portrait)
    XCTAssertEqual(game.current, .portrait)
  }

  @MainActor func testRotatingGameGetsRotatingSupport() {
    let game = SupportController.orientations(of: Game(.allButUpsideDown))
    XCTAssertEqual(game.mask, .allButUpsideDown)
    XCTAssertTrue(game.mask.contains(.portrait) && game.mask.contains(.landscape))
  }

  /// A landscape game whose app also allows portrait (Info.plist), as free rotation needs.
  @MainActor func testFreeRotationTakesEverythingTheAppAllows() {
    let followed = SupportController.orientations(
      app: .allButUpsideDown, game: .landscape, now: .landscapeLeft, free: false)
    XCTAssertEqual(followed.mask, .landscape)
    XCTAssertEqual(followed.current, .landscapeLeft)
    let free = SupportController.orientations(
      app: .allButUpsideDown, game: .landscape, now: .landscapeLeft, free: true)
    XCTAssertEqual(free.mask, .allButUpsideDown)
    XCTAssertEqual(free.current, .landscapeLeft)
  }

  @MainActor func testFreeRotationCannotExceedTheApp() {
    let free = SupportController.orientations(
      app: .landscape, game: .landscape, now: .landscapeRight, free: true)
    XCTAssertEqual(free.mask, .landscape)
    XCTAssertEqual(free.current, .landscapeRight)
  }

  @MainActor func testStartIsAlwaysAllowed() {
    let free = SupportController.orientations(
      app: .landscape, game: .portrait, now: .portrait, free: true)
    XCTAssertEqual(free.mask, .landscape)
    XCTAssertEqual(free.current, .landscapeRight)
    // The game and the app disagree: the app decides.
    let followed = SupportController.orientations(
      app: .landscape, game: .portrait, now: .unknown, free: false)
    XCTAssertEqual(followed.mask, .landscape)
    XCTAssertEqual(followed.current, .landscapeRight)
    let upsideDown = SupportController.orientations(
      app: .allButUpsideDown, game: .allButUpsideDown, now: .portraitUpsideDown, free: true)
    XCTAssertEqual(upsideDown.current, .portrait)
  }

  @MainActor func testFreeRotationIgnoresTheGameController() {
    let free = SupportController.orientations(of: Game(.landscape), free: true)
    XCTAssertEqual(free.mask, .all)
    XCTAssertEqual(free.current, .portrait)
    let support = SupportController(
      sdk: Cluefolk.shared, apiURL: URL(string: "https://cluefolk.com")!, game: free)
    XCTAssertEqual(support.supportedInterfaceOrientations, .all)
  }
}
