// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            exclude: ["COPYING", "README.md"],
            cSettings: [.define("FLOATING_POINT"), .define("USE_KISS_FFT"), .define("EXPORT", to: "")]
        ),
        .target(name: "Calls", path: "Sources/Calls"),
        .executableTarget(name: "Recorder", dependencies: ["CSpeexDSP", "Calls", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Recorder"),
        .executableTarget(name: "KaguWatch", dependencies: ["Calls"], path: "Sources/KaguWatch"),
    ]
)
