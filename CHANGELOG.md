# Changelog

## 0.3.2 — 2026-11-03

- Validate appearance values and embedded images before parsing or WebView decoding; reject excessive dimensions and pixel counts.
- Bound network responses and conversation history pagination; enforce bridge payload types.
- Keep attachment previews bounded while preserving JPEG orientation and WebView compatibility.
- Include the SDK privacy manifest in the Swift Package and both XCFramework slices.

## 0.3.1 — 2026-11-02

Support screen updates.

- Replies are signed with the operator's first name, for example "Anna · Support team", once the operator sets a name; otherwise "Support team".
- Delivery shows as compact ticks next to the time: one when sent, two when delivered, two at full strength once read.
- Inside a conversation the message box no longer shows the player ID.
- The "Talk to the team" button rests at the bottom of the home screen.

## 0.3.0 — 2026-11-02

First public release.

- Swift Package from `https://github.com/cluefolk/ios-sdk`; every release also has `Cluefolk.xcframework.zip` for projects without Swift Package Manager.
- `Cluefolk.sdkVersion` gives the SDK version.
- The built-in support screen reads conversation fields from the project configuration.
