# Cluefolk iOS SDK

In-game player support for iOS games. Players chat with your support team without leaving the game. The support screen is built into the SDK, so nothing is downloaded when it opens.

- Swift, Objective-C and Objective-C++, iOS 15 and later
- Works without sign-in: players start anonymously, linking a game account is optional
- Unity games use the [Cluefolk Unity package](https://github.com/cluefolk/unity-sdk), which wraps this SDK

## Requirements

- iOS 15 or later, Xcode 15 or later
- A Cluefolk project: copy its **Project ID** from **Settings → General** at [cluefolk.com](https://cluefolk.com)

## Install

### Swift Package Manager

In Xcode choose **File → Add Package Dependencies…**, enter `https://github.com/cluefolk/ios-sdk` and add the **Cluefolk** library to your app target. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/cluefolk/ios-sdk", from: "0.3.0"),
],
targets: [
    .target(name: "YourGame", dependencies: [.product(name: "Cluefolk", package: "ios-sdk")]),
]
```

### XCFramework

For projects without Swift Package Manager, every [release](https://github.com/cluefolk/ios-sdk/releases) has `Cluefolk.xcframework.zip` (devices and simulators). Add the framework to your app target with **Embed & Sign**.

## Quick start

All calls are made on the main thread (`@MainActor`). Keep a strong reference to your listener: the SDK holds it weakly.

```swift
import Cluefolk

let support = Cluefolk.shared
support.eventListener = supportListener // Optional: readiness, unread count, errors.
try support.initialize(CluefolkOptions(projectId: "YOUR_PROJECT_ID"))
```

`initialize` returns at once and reads saved credentials in the background. When it is done, `support.isReady` is `true` and the listener receives `onCluefolkReady()`. Then a support button opens the chat:

```swift
support.open(from: viewController)                // The support home screen.
support.openConversation("", from: viewController) // Straight to the player's current chat.
```

Objective-C: `#import <Cluefolk/Cluefolk-Swift.h>`, then `[CLFCluefolk.shared initialize:[[CLFOptions alloc] initWithProjectId:@"YOUR_PROJECT_ID"] error:&error]` and `[CLFCluefolk.shared openFrom:viewController]`.

Before the SDK is ready, operations fail with `notReady`; the listener and identity provider can be set earlier.

## Players

Support is anonymous by default. On first use the SDK creates a random install secret, keeps it in the Keychain and uses it to recognise the device, so the history survives restarts. No game backend is needed.

### The game's player ID

Pass your own player ID so the support team can find the player. It is shown to the team as **not verified**.

```swift
support.setPlayerId(game.playerId) // nil or "" clears it.
```

The ID is trimmed and kept in memory only. IDs longer than 256 characters or containing line breaks are ignored with `INVALID_ARGUMENT`. `logout()` clears it.

### Verified players (optional)

To link support to the game account, your game backend signs a short-lived identity token after the player signs in to the game: ES256 JWT, `typ: cluefolk-identity+jwt`, at most 5 minutes, `sub` = your player ID. Add the backend's public key in **Settings → Server connection → Players and sign-in**. Signing keys never go into the app.

```swift
// After the game login succeeds; the device's anonymous history moves to the account.
support.loginWithIdentity(identityToken) { error in
    // A support error must not fail the game login.
}

// Optional: let the SDK ask your backend for a fresh token when it needs a new session.
support.setIdentityTokenProvider { completion in
    game.fetchCluefolkIdentity(completion: completion) // (String?, NSError?) -> Void
}

// When the player signs out or switches accounts:
support.logout()
```

Sessions last 30 days and extend with use. If your backend cannot provide a token, support still opens anonymously and the listener receives the non-fatal `IDENTITY_UNAVAILABLE`. If the project requires sign-in, anonymous sessions fail with `IDENTITY_REQUIRED`.

## Context for the support team

```swift
try support.setAttributes(["level": 37])                // Keys registered in your project.
try support.setConversationContext(["screen": "shop"]) // Sent with the next new conversation.
```

The SDK also reports the platform, OS version, device model, app version and build, and language.

## Appearance

The support screen's look ships inside your game build. In Cluefolk open **Settings → Widget**, press **Download for build** and add the `<ID>_widget.json` file to your app bundle. Before opening support:

```swift
let file = Bundle.main.url(forResource: "YOUR_ID16_widget", withExtension: "json")!
let theme = try AppearanceBuilder(json: String(contentsOf: file, encoding: .utf8)).build()
support.setAppearance(theme)
```

`AppearanceBuilder()` without a file starts from the default look; change it in code with `title`, `mode`, `rotation`, `lightColors`/`darkColors`, `welcome`, `topics` and `contact`. `build()` throws `AppearanceError` with the reason if a value is invalid. `setAppearance(nil)` returns to the default look.

The screen turns like the game unless the theme sets `rotation` to `.free`; iOS never turns it beyond the orientations your Info.plist allows.

## Push notifications

Notifications about support replies go through your game server and your existing push setup; Cluefolk never holds device tokens and does not register with APNs. In your notification delegate:

```swift
support.handlePush(userInfo)                     // A notification arrived: updates the unread count.
support.openFromPush(userInfo, from: controller) // The player tapped it.
```

Both return `false` for notifications that are not from Cluefolk. See [Push notifications](https://cluefolk.com/guide/en/#push) for the server side.

## Events and errors

`CluefolkEventListener` receives `onCluefolkReady`, `onCluefolkOpened`, `onCluefolkClosed`, `onCluefolkUnreadChanged(_:)`, `onCluefolkIdentityTokenRequired(_:)`, `onCluefolkConversationCreated`, `onCluefolkConversationStatusChanged`, `onCluefolkMessageSent` and `onCluefolkError(_:)`. Error codes: `SUPPORT_UNAVAILABLE`, `IDENTITY_UNAVAILABLE`, `IDENTITY_REQUIRED`, `NOT_READY`, `NO_PRESENTING_CONTROLLER`, `INVALID_ARGUMENT`, `INVALID_LANGUAGE`, `WEB_CONTENT_TERMINATED`.

## Privacy and security

- HTTPS only. The support page is served by the SDK itself with a strict Content Security Policy; unknown navigation and bridge commands are refused.
- Credentials live in the Keychain. Images the player sent are kept on the device as encrypted previews, excluded from backups; `logout()` deletes them.
- The SDK never stores game access tokens or signing keys.

## More

- [Cluefolk guide: integrating the game client](https://cluefolk.com/guide/en/#client-integration)
- [Game server contract](https://cluefolk.com/game-integration.md)
- [Changelog](CHANGELOG.md) · [License: MIT](LICENSE)
