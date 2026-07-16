// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalVPN",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PersonalVPNCore", targets: ["PersonalVPNCore"]),
        .executable(name: "personalvpnd", targets: ["PersonalVPNDaemon"]),
        .executable(name: "personalvpnctl", targets: ["PersonalVPNCLI"]),
        .executable(name: "PersonalVPNApp", targets: ["PersonalVPNApp"]),
    ],
    targets: [
        .target(name: "PersonalVPNCore"),
        .executableTarget(name: "PersonalVPNDaemon", dependencies: ["PersonalVPNCore"]),
        .executableTarget(name: "PersonalVPNCLI", dependencies: ["PersonalVPNCore"]),
        .executableTarget(name: "PersonalVPNApp", dependencies: ["PersonalVPNCore"]),
        .testTarget(name: "PersonalVPNCoreTests", dependencies: ["PersonalVPNCore"]),
    ]
)
