// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LayoutBuddy",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "LayoutBuddy", targets: ["LayoutBuddy"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing", from: "0.3.1")
    ],
    targets: [
        .target(
            name: "LayoutBuddy",
            path: "LayoutBuddy",
            exclude: [
                "AppCoordinator.swift",
                "AppDelegate.swift",
                "EventTapController.swift",
                "KeyboardLayoutManager.swift",
                "LayoutBuddyApp.swift",
                "MenuBarController.swift",
                "LayoutPreferences.swift",
                "LayoutBuddy.entitlements",
                "Assets.xcassets"
            ]
        ),
        .testTarget(
            name: "LayoutBuddyTests",
            dependencies: [
                "LayoutBuddy",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "LayoutBuddyTests"
        )
    ]
)
