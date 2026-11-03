// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Cluefolk", platforms: [.iOS(.v15)],
  products: [.library(name: "Cluefolk", type: .dynamic, targets: ["Cluefolk"])],
  targets: [
    .target(name: "Cluefolk", dependencies: ["CluefolkPrivacy"]),
    .target(name: "CluefolkPrivacy", resources: [.process("PrivacyInfo.xcprivacy")]),
    .testTarget(name: "CluefolkTests", dependencies: ["Cluefolk"]),
  ])
