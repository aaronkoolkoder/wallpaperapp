// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Absolute path to the vendored static libraries.
//
// Linker search paths, unlike header search paths, are not resolved relative to the target, and
// SwiftPM does not expose the package root to `linkerSettings`. Deriving it from this manifest's
// own location is the only way to point at them that survives being cloned anywhere.
let vendorLibraryPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/install/lib")
    .path

// Only link the toolchain when it has actually been built.
//
// `ShaderBridge.cpp` already compiles to a stub when the headers are missing, but that only
// fixes the compile step: naming the libraries unconditionally still fails the link on a fresh
// clone with `ld: library 'glslang' not found`. The manifest is ordinary Swift, so it can check.
//
// Scripts/vendor-shader-tools.sh touches this file when it finishes, because SwiftPM caches the
// evaluated manifest and would otherwise keep the "absent" answer after the libraries appear.
let vendoredToolchainIsBuilt = FileManager.default.fileExists(
    atPath: vendorLibraryPath + "/libglslang.a"
)

let shaderToolchainLinkerSettings: [LinkerSetting] = vendoredToolchainIsBuilt
    ? [
        .unsafeFlags([
            "-L\(vendorLibraryPath)",
            "-lglslang", "-lMachineIndependent", "-lGenericCodeGen",
            "-lOSDependent", "-lSPIRV", "-lglslang-default-resource-limits",
            "-lspirv-cross-core", "-lspirv-cross-glsl", "-lspirv-cross-msl",
        ], .when(platforms: [.macOS])),
    ]
    : []

let package = Package(
    name: "Diorama",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Diorama", targets: ["DioramaApp"]),
        .executable(name: "wetool", targets: ["wetool"]),
        .library(name: "WEFormat", targets: ["WEFormat"]),
    ],
    targets: [
        // Leaf: pure parsing. No GPU, no UI, no AppKit.
        .target(name: "WEFormat"),

        // C++ bridge over the vendored shader toolchain. Built by
        // Scripts/vendor-shader-tools.sh; the target compiles to a stub when it is absent, so a
        // fresh clone still builds without running the vendor step first.
        .target(
            name: "ShaderBridge",
            // The staged vendor headers are compiler inputs, not sources.
            exclude: ["vendor"],
            cxxSettings: [
                .headerSearchPath("include"),
                // Staged by Scripts/vendor-shader-tools.sh. Header search paths are relative to
                // the target, which is why the vendored headers are copied in rather than
                // referenced where they were built.
                .headerSearchPath("vendor"),
            ],
            linkerSettings: shaderToolchainLinkerSettings
        ),

        // Leaf: WE GLSL -> MSL.
        .target(name: "ShaderTranspiler", dependencies: ["ShaderBridge"]),

        // Leaf: Metal render graph, FBO pool, caches.
        .target(name: "MetalRenderer"),

        // Leaf: desktop surfaces, display topology, power policy.
        .target(name: "WallpaperKit"),

        // Leaf: compatibility reports, perf sampling.
        .target(name: "Diagnostics"),

        .target(name: "LibraryKit", dependencies: ["WEFormat", "Diagnostics"]),

        .target(name: "SceneEngine", dependencies: ["WEFormat", "MetalRenderer", "ShaderTranspiler", "Diagnostics"]),

        .target(name: "PlayerCore", dependencies: ["WallpaperKit", "SceneEngine", "LibraryKit", "WEFormat", "Diagnostics"]),

        .executableTarget(
            name: "DioramaApp",
            dependencies: ["PlayerCore", "WallpaperKit", "LibraryKit", "SceneEngine", "WEFormat", "Diagnostics"]
        ),

        .executableTarget(name: "wetool", dependencies: ["WEFormat", "ShaderTranspiler", "LibraryKit", "SceneEngine", "MetalRenderer"]),

        .testTarget(name: "WEFormatTests", dependencies: ["WEFormat"]),
        .testTarget(name: "ShaderTranspilerTests", dependencies: ["ShaderTranspiler"]),
        .testTarget(name: "SceneEngineTests", dependencies: ["SceneEngine"]),
        .testTarget(name: "WallpaperKitTests", dependencies: ["WallpaperKit"]),
        .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit"]),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore", "WEFormat"]),
        .testTarget(name: "DioramaAppTests", dependencies: ["DioramaApp", "LibraryKit"]),
        .testTarget(name: "MetalRendererTests", dependencies: ["MetalRenderer"]),
    ],
    cxxLanguageStandard: .cxx17
)
