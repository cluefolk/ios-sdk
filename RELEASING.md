# Releasing

For maintainers. A release is a tag of this repository (Swift Package Manager reads tags) and a GitHub release with the XCFramework.

1. Embed the current support screen build (`Sources/Cluefolk/WidgetAssets.swift`, generated; do not edit by hand).
2. Set `Cluefolk.sdkVersion` in `Sources/Cluefolk/Cluefolk.swift` and add the release to `CHANGELOG.md`.
3. Check the build and tests:

   ```sh
   xcodebuild -quiet -scheme Cluefolk -destination 'generic/platform=iOS Simulator' \
     CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES build
   xcodebuild -scheme Cluefolk -destination 'platform=iOS Simulator,name=<an installed iPhone>' test
   ```

4. Build the XCFramework (devices and simulators) with its checksum:

   ```sh
   Scripts/build-xcframework.sh 0.3.0
   ```

5. Tag the commit with the version (`0.3.0`, no `v`), push the tag and create a GitHub release with the changelog entry and `build/Cluefolk.xcframework.zip`.

Then update the Unity package: `Scripts/update-ios-framework.sh <path to this repository>`.
