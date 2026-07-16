// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TechMarkdown",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TechMarkdown", targets: ["TechMarkdown"])
    ],
    targets: [
        .executableTarget(
            name: "TechMarkdown",
            path: "TechMarkdown",
            exclude: ["TechMarkdown.entitlements", "Info.plist"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TechMarkdownTests",
            dependencies: ["TechMarkdown"],
            path: "Tests/TechMarkdownTests"
        )
    ]
)
