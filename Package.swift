// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FacebookWebhookRelay",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "FacebookWebhookRelay",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "FacebookWebhookRelayTests",
            dependencies: [
                .target(name: "FacebookWebhookRelay"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }

// Add Firebase only for Apple platforms
#if os(macOS) || os(iOS)
package.dependencies.append(
    .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0")
)
package.targets[0].dependencies.append(
    .product(name: "FirebaseCore", package: "firebase-ios-sdk")
)
#endif
