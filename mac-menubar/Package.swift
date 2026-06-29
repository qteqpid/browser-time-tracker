// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BrowserTimeMenubar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BrowserTimeMenubar", targets: ["BrowserTimeMenubar"])
    ],
    targets: [
        .executableTarget(
            name: "BrowserTimeMenubar",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
