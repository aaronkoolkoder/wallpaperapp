import Foundation
import Metal
import ShaderTranspiler

/// True when this machine has a GPU and the shader toolchain has been vendored.
///
/// Both are environmental rather than properties of the code under test: a CI runner without a
/// Metal device, or a clone where `Scripts/vendor-shader-tools.sh` has not been run, should skip
/// these rather than report them as failures. A red suite for something nobody broke teaches
/// people to ignore the suite.
var gpuAndToolchainAvailable: Bool {
    MTLCreateSystemDefaultDevice() != nil
        && !(TranspilerBackendFactory.makeDefault() is UnavailableTranspilerBackend)
}
