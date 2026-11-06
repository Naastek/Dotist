// swift-tools-version: 5.9
import Foundation
import PackageDescription

struct BuildConfiguration: Decodable {
    let minimumMacOS: String
}

let configuration = try JSONDecoder().decode(
    BuildConfiguration.self,
    from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("app.json"))
)

let sparkle = ProcessInfo.processInfo.environment["DOTIST_SPARKLE_XCFRAMEWORK"].map {
    Target.binaryTarget(name: "Sparkle", path: $0)
} ?? .binaryTarget(
    name: "Sparkle",
    url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip",
    checksum: "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
)

// Packaged apps copy their resources into Contents/Resources. Avoid SwiftPM's
// generated accessor, which embeds an absolute build-directory fallback.
let packagedBuild = ProcessInfo.processInfo.environment["DOTIST_PACKAGED_BUILD"] == "1"

let package = Package(
    name: "DotistNative",
    platforms: [.macOS(configuration.minimumMacOS)],
    products: [
        .library(name: "DotistCore", targets: ["DotistCore"]),
        .executable(name: "DotistNative", targets: ["DotistApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "DotistCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        sparkle,
        .executableTarget(name: "DotistApp", dependencies: ["DotistCore", "Sparkle", .product(name: "GRDB", package: "GRDB.swift"), .product(name: "MCP", package: "swift-sdk")], exclude: packagedBuild ? ["Resources"] : [], resources: packagedBuild ? [] : [.process("Resources")], swiftSettings: packagedBuild ? [.define("DOTIST_PACKAGED_BUILD")] : [], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DotistCoreTests", dependencies: ["DotistCore"]),
        .testTarget(name: "DotistAppTests", dependencies: ["DotistApp"]),
    ]
)
