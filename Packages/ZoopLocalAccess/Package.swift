// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZoopLocalAccess",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZoopLocalAccessCore", targets: ["ZoopLocalAccessCore"]),
        .executable(name: "zoop-local-access", targets: ["zoop-local-access"]),
    ],
    dependencies: [
        // Supply-chain: pinned EXACT (not `from:`) so a clean resolve can't auto-pull a newer —
        // potentially compromised — upstream release. Must match the same exact version in the
        // other Packages/*/Package.swift and project.yml, or SPM resolution fails. Bump deliberately.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "ZoopLocalAccessCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "zoop-local-access",
            dependencies: ["ZoopLocalAccessCore"]
        ),
        .testTarget(
            name: "ZoopLocalAccessCoreTests",
            dependencies: [
                "ZoopLocalAccessCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
