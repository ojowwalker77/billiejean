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
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "DSP", targets: ["DSP"]),
        .library(name: "NowPlaying", targets: ["NowPlaying"]),
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
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
            ]
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
        .testTarget(
            name: "DSPTests",
            dependencies: ["DSP"]
        ),
    ]
)
