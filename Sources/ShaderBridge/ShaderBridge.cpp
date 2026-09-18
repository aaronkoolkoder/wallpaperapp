#include "include/ShaderBridge.h"

#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <glslang/SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>

namespace {

std::once_flag g_initOnce;

char *duplicate(const std::string &value) {
    char *result = static_cast<char *>(std::malloc(value.size() + 1));
    if (result == nullptr) {
        return nullptr;
    }
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

}  // namespace

void diorama_shader_bridge_initialize(void) {
    // glslang keeps process-global state and must be initialised exactly once. Wallpapers are
    // compiled from several places, so guarding it here rather than expecting callers to
    // remember avoids a class of crash that only shows up under concurrent imports.
    std::call_once(g_initOnce, []() { glslang::InitializeProcess(); });
}

int diorama_glsl_to_msl(const char *glsl,
                        DioramaShaderStage stage,
                        char **out_msl,
                        char **out_error) {
    if (glsl == nullptr || out_msl == nullptr || out_error == nullptr) {
        return 1;
    }
    *out_msl = nullptr;
    *out_error = nullptr;

    diorama_shader_bridge_initialize();

    const EShLanguage language =
        stage == DioramaShaderStageVertex ? EShLangVertex : EShLangFragment;

    glslang::TShader shader(language);
    const char *sources[] = {glsl};
    shader.setStrings(sources, 1);

    // Target Vulkan semantics because that is what produces SPIR-V glslang will emit and
    // SPIRV-Cross can consume. The Vulkan runtime is never involved.
    shader.setEnvInput(glslang::EShSourceGlsl, language, glslang::EShClientVulkan, 100);
    shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    // Wallpaper Engine shaders declare no layout locations or descriptor bindings, since
    // OpenGL does not require them. Without auto-assignment glslang rejects them outright.
    shader.setAutoMapLocations(true);
    shader.setAutoMapBindings(true);

    const EShMessages messages =
        static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules | EShMsgDefault);

    if (!shader.parse(GetDefaultResources(), 450, false, messages)) {
        std::string error = "parse failed:\n";
        error += shader.getInfoLog();
        *out_error = duplicate(error);
        return 2;
    }

    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages)) {
        std::string error = "link failed:\n";
        error += program.getInfoLog();
        *out_error = duplicate(error);
        return 3;
    }
    if (!program.mapIO()) {
        *out_error = duplicate("mapIO failed");
        return 4;
    }

    std::vector<unsigned int> spirv;
    glslang::GlslangToSpv(*program.getIntermediate(language), spirv);
    if (spirv.empty()) {
        *out_error = duplicate("SPIR-V generation produced nothing");
        return 5;
    }

    try {
        spirv_cross::CompilerMSL compiler(std::move(spirv));

        spirv_cross::CompilerMSL::Options options;
        options.platform = spirv_cross::CompilerMSL::Options::macOS;
        // Metal 3.0 ships with macOS 13 and this app requires 26, so nothing older is worth
        // targeting.
        options.set_msl_version(3, 0);
        // Argument buffers are a later optimisation; plain bindings keep the generated entry
        // point predictable enough to bind against from Swift.
        options.argument_buffers = false;
        compiler.set_msl_options(options);

        std::string msl = compiler.compile();
        if (msl.empty()) {
            *out_error = duplicate("MSL generation produced nothing");
            return 6;
        }
        *out_msl = duplicate(msl);
        return *out_msl == nullptr ? 7 : 0;
    } catch (const std::exception &error) {
        // SPIRV-Cross signals unsupported constructs by throwing; letting that cross back into
        // Swift would terminate the process rather than degrade one wallpaper.
        *out_error = duplicate(std::string("MSL translation failed: ") + error.what());
        return 8;
    } catch (...) {
        *out_error = duplicate("MSL translation failed with an unknown error");
        return 9;
    }
}

void diorama_shader_free(char *value) {
    std::free(value);
}
