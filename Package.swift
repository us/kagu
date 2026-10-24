// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            exclude: ["COPYING", "README.md"],
            cSettings: [.define("FLOATING_POINT"), .define("USE_KISS_FFT"), .define("EXPORT", to: "")]
        ),
        .executableTarget(name: "Recorder", dependencies: ["CSpeexDSP"], path: "Sources/Recorder"),
    ]
)
