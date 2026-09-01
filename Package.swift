// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "parblo-a610-craft-driver",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "parblo-a610-craft-driver", targets: ["ParbloA610CraftDriver"]),
        .executable(name: "ParbloA610Settings", targets: ["ParbloA610Settings"]),
    ],
    targets: [
        .target(name: "CUCLogic"),
        .target(
            name: "ParbloA610Core",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ParbloA610CraftDriver",
            dependencies: ["CUCLogic", "ParbloA610Core"],
            swiftSettings: [
                // The daemon is single threaded and lives on one run loop; strict
                // concurrency checking catches nothing here, but it breaks the
                // bridges to IOKit.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "ParbloA610Settings",
            dependencies: ["ParbloA610Core"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ParbloA610CraftDriverTests",
            dependencies: ["ParbloA610CraftDriver", "ParbloA610Core", "ParbloA610Settings"],
            swiftSettings: [
                // Same mode as the main target: the driver is single threaded
                // and lives on one run loop, strict concurrency checking
                // catches nothing here.
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
