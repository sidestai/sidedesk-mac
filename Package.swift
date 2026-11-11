// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SidestMac",
    platforms: [.macOS(.v13)],
    // Sparkle 2.x：macOS 自动更新框架（对应 Windows 侧 C# 的 Velopack，见任务 #63）。
    // 上游是 binaryTarget（下载 xcframework 产物），要求 macOS 12+，与本包 13 兼容。
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        // 领域地基层：组合根（DI 容器）+ 后续 Models/Settings/Lang/日志。
        // 对应 Windows C# 的 SideDesk.Core（纯领域，平台无关）。
        .target(
            name: "SideDeskCore",
            path: "Sources/SideDeskCore",
            resources: [.copy("Resources/langs"), .copy("Resources/themes")]
        ),
        // 平台无关服务层：本地 SQLite 持久化地基（LocalDbService）+ 管理器。
        // 对应 Windows C# 的 SideDesk.Services 中不依赖平台/云的部分。
        .target(
            name: "SideDeskServices",
            dependencies: ["SideDeskCore"],
            path: "Sources/SideDeskServices",
            resources: [.copy("Resources/data-templates")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 应用外壳（可执行）：AppKit 面板 + 热键 + AX 窗口让位，装配组合根。
        // rpath `@executable_path/../Frameworks`：SPM 自带的 rpath 指向构建机上的产物缓存目录，
        // 打包后不存在，故显式加上 bundle 内查找路径（build.sh 把 Sparkle.framework 放进 Contents/Frameworks）。
        .executableTarget(
            name: "SidestMac",
            dependencies: [
                "SideDeskCore",
                "SideDeskServices",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/SidestMac",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "SideDeskCoreTests",
            dependencies: ["SideDeskCore"],
            path: "Tests/SideDeskCoreTests"
        ),
        .testTarget(
            name: "SideDeskServicesTests",
            dependencies: ["SideDeskServices"],
            path: "Tests/SideDeskServicesTests"
        ),
    ]
)
