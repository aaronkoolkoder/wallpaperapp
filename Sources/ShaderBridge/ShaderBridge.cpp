#include "include/ShaderBridge.h"

#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

// The toolchain is fetched and built by Scripts/vendor-shader-tools.sh rather than committed,
// so a fresh clone does not have it. Rather than making a CMake step a precondition for
// `swift build`, the bridge compiles to a stub that reports its own absence — the Swift side
// already treats that as "shaders unavailable" and degrades through the normal compatibility
// path.
#if __has_include(<glslang/Public/ShaderLang.h>) && __has_include(<spirv_msl.hpp>)
#define DIORAMA_SHADER_TOOLCHAIN_AVAILABLE 1
#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <glslang/SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>
#else
#define DIORAMA_SHADER_TOOLCHAIN_AVAILABLE 0
#endif

namespace {

#if DIORAMA_SHADER_TOOLCHAIN_AVAILABLE
std::once_flag g_initOnce;
#endif

#if DIORAMA_SHADER_TOOLCHAIN_AVAILABLE

/// Minimal JSON string escaping. Shader resource names are GLSL identifiers, so this only
/// ever has work to do if SPIRV-Cross invents a name; escaping anyway keeps a surprising
/// name from producing a reflection blob Swift cannot parse.
std::string escape(const std::string &value) {
    std::string out;
    out.reserve(value.size() + 2);
    for (const char character : value) {
        switch (character) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(character) < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", character);
                    out += buffer;
                } else {
                    out += character;
                }
        }
    }
    return out;
}

/// Appends `"name":<slot>` entries for resources that survived translation.
///
/// `get_automatic_msl_resource_binding` returns the slot SPIRV-Cross actually assigned, or
/// ~0u for a resource it eliminated. Skipping the eliminated ones is the point: the caller
/// binds by name, so a resource absent from this list is one it must not bind.
void appendResources(std::string &json,
                     const spirv_cross::CompilerMSL &compiler,
                     const spirv_cross::SmallVector<spirv_cross::Resource> &resources,
                     bool secondary) {
    bool first = true;
    for (const auto &resource : resources) {
        const uint32_t slot = secondary
            ? compiler.get_automatic_msl_resource_binding_secondary(resource.id)
            : compiler.get_automatic_msl_resource_binding(resource.id);
        if (slot == uint32_t(-1)) {
            continue;
        }
        if (!first) {
            json += ",";
        }
        first = false;
        json += "{\"name\":\"" + escape(resource.name) + "\",\"slot\":" + std::to_string(slot) + "}";
    }
}

/// Describes where the translated shader expects its resources, as JSON.
std::string reflect(const spirv_cross::CompilerMSL &compiler, spv::ExecutionModel model) {
    const spirv_cross::ShaderResources resources = compiler.get_shader_resources();

    std::string json = "{\"entryPoint\":\"";
    json += escape(compiler.get_cleansed_entry_point_name("main", model));
    json += "\",\"buffers\":[";
    appendResources(json, compiler, resources.uniform_buffers, false);
    json += "],\"members\":[";
    // The byte offsets SPIRV-Cross baked into the generated struct. The Swift side computes
    // the same offsets from the published std140 rules; reporting them here is what lets a
    // test check the two agree rather than trusting that they do.
    {
        bool firstMember = true;
        for (const auto &buffer : resources.uniform_buffers) {
            const spirv_cross::SPIRType &type = compiler.get_type(buffer.base_type_id);
            for (uint32_t index = 0; index < uint32_t(type.member_types.size()); ++index) {
                if (!firstMember) {
                    json += ",";
                }
                firstMember = false;
                json += "{\"name\":\"" + escape(compiler.get_member_name(buffer.base_type_id, index)) +
                        "\",\"offset\":" +
                        std::to_string(compiler.type_struct_member_offset(type, index)) + "}";
            }
        }
    }
    json += "],\"textures\":[";
    appendResources(json, compiler, resources.sampled_images, false);
    appendResources(json, compiler, resources.separate_images, false);
    json += "],\"samplers\":[";
    // A GLSL-sourced combined image sampler carries both indices: the texture in the primary
    // binding and the sampler in the secondary one.
    appendResources(json, compiler, resources.sampled_images, true);
    appendResources(json, compiler, resources.separate_samplers, false);
    json += "],\"inputs\":[";
    bool first = true;
    for (const auto &input : resources.stage_inputs) {
        if (!compiler.has_decoration(input.id, spv::DecorationLocation)) {
            continue;
        }
        if (!first) {
            json += ",";
        }
        first = false;
        json += "{\"name\":\"" + escape(input.name) + "\",\"location\":" +
                std::to_string(compiler.get_decoration(input.id, spv::DecorationLocation)) + "}";
    }
    json += "]}";
    return json;
}

#endif  // DIORAMA_SHADER_TOOLCHAIN_AVAILABLE

char *duplicate(const std::string &value) {
    char *result = static_cast<char *>(std::malloc(value.size() + 1));
    if (result == nullptr) {
        return nullptr;
    }
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

}  // namespace

#if !DIORAMA_SHADER_TOOLCHAIN_AVAILABLE

void diorama_shader_bridge_initialize(void) {}

int diorama_glsl_to_msl(const char *glsl,
                        DioramaShaderStage stage,
                        char **out_msl,
                        char **out_reflection,
                        char **out_error) {
    (void)glsl;
    (void)stage;
    if (out_msl != nullptr) {
        *out_msl = nullptr;
    }
    if (out_reflection != nullptr) {
        *out_reflection = nullptr;
    }
    if (out_error != nullptr) {
        *out_error = duplicate(
            "shader toolchain not built - run Scripts/vendor-shader-tools.sh");
    }
    return 100;
}

void diorama_shader_free(char *value) {
    std::free(value);
}

#else

void diorama_shader_bridge_initialize(void) {
    // glslang keeps process-global state and must be initialised exactly once. Wallpapers are
    // compiled from several places, so guarding it here rather than expecting callers to
    // remember avoids a class of crash that only shows up under concurrent imports.
    std::call_once(g_initOnce, []() { glslang::InitializeProcess(); });
}

int diorama_glsl_to_msl(const char *glsl,
                        DioramaShaderStage stage,
                        char **out_msl,
                        char **out_reflection,
                        char **out_error) {
    if (glsl == nullptr || out_msl == nullptr || out_error == nullptr) {
        return 1;
    }
    *out_msl = nullptr;
    *out_error = nullptr;
    if (out_reflection != nullptr) {
        *out_reflection = nullptr;
    }

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

        if (out_reflection != nullptr) {
            const spv::ExecutionModel model = stage == DioramaShaderStageVertex
                                                  ? spv::ExecutionModelVertex
                                                  : spv::ExecutionModelFragment;
            *out_reflection = duplicate(reflect(compiler, model));
            if (*out_reflection == nullptr) {
                *out_error = duplicate("could not allocate the reflection description");
                return 10;
            }
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

#endif  // DIORAMA_SHADER_TOOLCHAIN_AVAILABLE
