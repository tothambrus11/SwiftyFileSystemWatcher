// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "SwiftyFileSystemWatcher",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "SwiftyFileSystemWatcher", targets: ["SwiftyFileSystemWatcher"])
  ],
  targets: [
    .target(name: "SwiftyFileSystemWatcher"),
    .testTarget(
      name: "SwiftyFileSystemWatcherTests",
      dependencies: ["SwiftyFileSystemWatcher"]),
  ]
)
