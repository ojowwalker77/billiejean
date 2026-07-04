// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Vinylfy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VinylfyStudio", targets: ["VinylfyStudio"]),
        .executable(name: "VinylfyHearIt", targets: ["VinylfyHearIt"]),
        .executable(name: "VinylfyPlayerHelper", targets: ["VinylfyPlayerHelper"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "DSP", targets: ["DSP"]),
        .library(name: "NowPlaying", targets: ["NowPlaying"]),
        .library(name: "PlayerBridge", targets: ["PlayerBridge"]),
        .library(name: "VinylEngine", targets: ["VinylEngine"]),
    ],
    targets: [
        .target(
            name: "AudioCapture",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "DSP",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .target(
            name: "NowPlaying",
            dependencies: ["PlayerBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
            ]
        ),
        .target(
            name: "PlayerBridge"
        ),
        .target(
            name: "VinylEngine",
            dependencies: ["AudioCapture", "DSP"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "VinylfyStudio",
            dependencies: ["VinylEngine", "DSP", "NowPlaying"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "VinylfyHearIt",
            dependencies: ["AudioCapture", "DSP", "VinylEngine", "NowPlaying"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "VinylfyPlayerHelper",
            dependencies: ["PlayerBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("MusicKit"),
            ]
        ),
        .testTarget(
            name: "DSPTests",
            dependencies: ["DSP"]
        ),
        .testTarget(
            name: "PlayerBridgeTests",
            dependencies: ["PlayerBridge"]
        ),
    ]
)
