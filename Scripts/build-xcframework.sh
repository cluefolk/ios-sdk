#!/bin/sh
# Builds Cluefolk.xcframework (iOS devices and simulators) for apps and engines
# that do not use Swift Package Manager, such as the Unity package, and zips it
# with its SwiftPM checksum for a GitHub release.
#
# Usage: Scripts/build-xcframework.sh <version> [output directory, default build]
set -eu
version=${1:?usage: Scripts/build-xcframework.sh <version> [output directory]}
cd "$(dirname "$0")/.."
out=$(mkdir -p "${2:-build}" && cd "${2:-build}" && pwd)
privacy="$PWD/Sources/CluefolkPrivacy/PrivacyInfo.xcprivacy"
plutil -lint "$privacy" >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

frameworks=""
for platform in iphoneos iphonesimulator; do
  case $platform in
    iphoneos) destination="generic/platform=iOS" ;;
    *) destination="generic/platform=iOS Simulator" ;;
  esac
  xcodebuild archive -quiet -scheme Cluefolk -destination "$destination" \
    -archivePath "$work/$platform.xcarchive" -derivedDataPath "$work/$platform" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
  framework="$work/$platform.xcarchive/Products/usr/local/lib/Cluefolk.framework"
  intermediates="$work/$platform/Build/Intermediates.noindex/ArchiveIntermediates/Cluefolk"
  # SwiftPM archives a bare framework: add the Objective-C header, the module map
  # and the Swift interfaces so Objective-C, C++ and Swift apps can import it.
  mkdir -p "$framework/Headers" "$framework/Modules"
  cp "$intermediates/IntermediateBuildFilesPath/GeneratedModuleMaps-$platform/Cluefolk-Swift.h" "$framework/Headers/"
  cp -R "$intermediates/BuildProductsPath/Release-$platform/Cluefolk.swiftmodule" "$framework/Modules/"
  # ABI digests and source info carry build-machine paths; apps do not need them.
  rm -rf "$framework/Modules/Cluefolk.swiftmodule/"*.abi.json "$framework/Modules/Cluefolk.swiftmodule/Project"
  cat > "$framework/Modules/module.modulemap" <<'MAP'
framework module Cluefolk {
  header "Cluefolk-Swift.h"
  requires objc
}
MAP
  # The App Store reads these from embedded frameworks; Xcode signs on embedding.
  plutil -replace CFBundleIdentifier -string com.cluefolk.sdk "$framework/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$version" "$framework/Info.plist"
  plutil -replace CFBundleVersion -string "$version" "$framework/Info.plist"
  cp "$privacy" "$framework/PrivacyInfo.xcprivacy"
  rm -rf "$framework/_CodeSignature"
  frameworks="$frameworks -framework $framework"
done

rm -rf "$out/Cluefolk.xcframework" "$out/Cluefolk.xcframework.zip"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $frameworks -output "$out/Cluefolk.xcframework" >/dev/null
(cd "$out" && ditto -c -k --sequesterRsrc --keepParent Cluefolk.xcframework Cluefolk.xcframework.zip)
swift package compute-checksum "$out/Cluefolk.xcframework.zip" > "$out/Cluefolk.xcframework.zip.sha256"
echo "$out/Cluefolk.xcframework.zip $(cat "$out/Cluefolk.xcframework.zip.sha256")"
