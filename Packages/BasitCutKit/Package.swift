// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BasitCutKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BasitCutCore", targets: ["BasitCutCore"]),
        .library(name: "BasitCutMedia", targets: ["BasitCutMedia"]),
    ],
    targets: [
        // Pure project/timeline model. Foundation only — must never import AVFoundation.
        .target(name: "BasitCutCore"),
        // AVFoundation layer: inspection, composition, export.
        .target(name: "BasitCutMedia", dependencies: ["BasitCutCore"]),
        .testTarget(name: "BasitCutCoreTests", dependencies: ["BasitCutCore"]),
        .testTarget(name: "BasitCutMediaTests", dependencies: ["BasitCutMedia"]),
    ]
)
