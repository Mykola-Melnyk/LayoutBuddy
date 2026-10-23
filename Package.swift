// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LayoutBuddy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LayoutBuddy", targets: ["LayoutBuddy"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LayoutBuddy",
            path: "LayoutBuddy",
            exclude: [
                "AppDelegate.swift",
                "LayoutBuddyApp.swift",
                "LayoutBuddy.entitlements",
                "Assets.xcassets"
            ],
            resources: [
                .copy("Resources/words-en.txt"),
                .copy("Resources/words-uk.txt")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "LayoutBuddyTests",
            dependencies: ["LayoutBuddy"],
            path: "LayoutBuddyTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
