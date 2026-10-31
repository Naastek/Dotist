// swift-tools-version: 5.9
import Foundation
import PackageDescription

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let rustLibrary = ProcessInfo.processInfo.environment["DOTIST_RUST_LIB_DIR"]
    ?? project.appendingPathComponent(".cache/native-migration/rust-target/debug").path
let sparkle = ProcessInfo.processInfo.environment["DOTIST_SPARKLE_XCFRAMEWORK"].map {
    Target.binaryTarget(name: "Sparkle", path: $0)
} ?? .binaryTarget(
    name: "Sparkle",
    url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip",
    checksum: "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
)

let package = Package(
    name: "DotistNative",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "DotistCore", targets: ["DotistCore"]),
        .executable(name: "DotistNative", targets: ["DotistApp"]),
    ],
    targets: [
        .systemLibrary(name: "DotistCoreFFI", path: "Bridge"),
        .target(name: "DotistCore", dependencies: ["DotistCoreFFI"], linkerSettings: [.unsafeFlags(["-L", rustLibrary])]),
        sparkle,
        .executableTarget(name: "DotistApp", dependencies: ["DotistCore", "Sparkle"], resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DotistCoreTests", dependencies: ["DotistCore"]),
        .testTarget(name: "DotistAppTests", dependencies: ["DotistApp"]),
    ]
)
