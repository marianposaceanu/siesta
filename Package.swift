// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "siesta",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "siesta", targets: ["siesta"]),
        .library(name: "SiestaCore", targets: ["SiestaCore"]),
        .executable(name: "selftest", targets: ["selftest"]),
    ],
    targets: [
        .target(name: "SiestaCore"),
        .executableTarget(name: "siesta", dependencies: ["SiestaCore"]),
        .executableTarget(name: "selftest", dependencies: ["SiestaCore"]),
    ]
)
