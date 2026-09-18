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
            linkerSettings: [
                .unsafeFlags([
                    "-L\(vendorLibraryPath)",
                    "-lglslang", "-lMachineIndependent", "-lGenericCodeGen",
                    "-lOSDependent", "-lSPIRV", "-lglslang-default-resource-limits",
                    "-lspirv-cross-core", "-lspirv-cross-glsl", "-lspirv-cross-msl",
                ], .when(platforms: [.macOS])),
            ]
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

        .target(name: "PlayerCore", dependencies: ["WallpaperKit", "SceneEngine", "LibraryKit", "Diagnostics"]),

        .executableTarget(
            name: "DioramaApp",
            dependencies: ["PlayerCore", "WallpaperKit", "LibraryKit", "SceneEngine", "Diagnostics"]
        ),

        .executableTarget(name: "wetool", dependencies: ["WEFormat", "ShaderTranspiler", "LibraryKit", "SceneEngine", "MetalRenderer"]),

        .testTarget(name: "WEFormatTests", dependencies: ["WEFormat"]),
        .testTarget(name: "ShaderTranspilerTests", dependencies: ["ShaderTranspiler"]),
        .testTarget(name: "SceneEngineTests", dependencies: ["SceneEngine"]),
        .testTarget(name: "WallpaperKitTests", dependencies: ["WallpaperKit"]),
        .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit"]),
        .testTarget(name: "MetalRendererTests", dependencies: ["MetalRenderer"]),
    ],
    cxxLanguageStandard: .cxx17
)
