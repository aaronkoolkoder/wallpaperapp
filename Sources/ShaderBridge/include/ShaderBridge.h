#ifndef DIORAMA_SHADER_BRIDGE_H
#define DIORAMA_SHADER_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Shader stage being compiled.
typedef enum {
    DioramaShaderStageVertex = 0,
    DioramaShaderStageFragment = 1,
} DioramaShaderStage;

/// Translate GLSL to Metal Shading Language.
///
/// Wallpaper Engine ships GLSL; Metal needs MSL. The route is GLSL -> SPIR-V (glslang) -> MSL
/// (SPIRV-Cross), which is the same path MoltenVK takes, minus the Vulkan runtime in between.
///
/// On success returns 0 and sets `out_msl` to a newly allocated string the caller must release
/// with `diorama_shader_free`. On failure returns non-zero and sets `out_error` instead.
///
/// `out_reflection` receives a JSON description of where the translated shader actually expects
/// its resources. It is not optional detail: SPIRV-Cross renumbers bindings into compact Metal
/// slots and drops resources the shader never reads, so a declared-but-unused sampler shifts
/// every texture after it. Binding by declaration order would silently swap textures. The shape
/// is:
///
///     {"entryPoint":"main0",
///      "buffers":[{"name":"DioramaUniforms","slot":0}],
///      "textures":[{"name":"g_Texture0","slot":0}],
///      "samplers":[{"name":"g_Texture0","slot":0}],
///      "inputs":[{"name":"v_TexCoord","location":0}]}
///
/// May be NULL when the caller does not want it.
int diorama_glsl_to_msl(const char *glsl,
                        DioramaShaderStage stage,
                        char **out_msl,
                        char **out_reflection,
                        char **out_error);

/// Release a string returned by this bridge.
void diorama_shader_free(char *value);

/// One-time global setup. Safe to call repeatedly; only the first call does anything.
void diorama_shader_bridge_initialize(void);

#ifdef __cplusplus
}
#endif

#endif
