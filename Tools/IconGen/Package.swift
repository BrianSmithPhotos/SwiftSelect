// swift-tools-version: 5.10
import PackageDescription

// Deliberately a package of its own rather than a target in the app's
// Package.swift: this is a generator run by hand when the icon changes, not
// something the app links against, so it stays off the app's dependency graph.
let package = Package(
    name: "IconGen",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/BrianSmithPhotos/IconForge.git", branch: "main")
    ],
    targets: [
        .executableTarget(name: "IconGen", dependencies: ["IconForge"])
    ]
)
