// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "Hostess",
	platforms: [
		.macOS(.v13),
	],
	products: [
		.library(name: "HostessCore", targets: ["HostessCore"]),
		.library(name: "HostessShared", targets: ["HostessShared"]),
		.executable(name: "Hostess", targets: ["Hostess"]),
		.executable(name: "HostessHelper", targets: ["HostessHelper"]),
	],
	targets: [
		.target(name: "HostessCore"),
		.target(name: "HostessShared"),
		.executableTarget(
			name: "Hostess",
			dependencies: ["HostessCore", "HostessShared"]
		),
		.executableTarget(
			name: "HostessHelper",
			dependencies: ["HostessCore", "HostessShared"]
		),
		.testTarget(
			name: "HostessCoreTests",
			dependencies: ["HostessCore"]
		),
		.testTarget(
			name: "HostessSharedTests",
			dependencies: ["HostessShared"]
		),
	]
)
