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
int diorama_glsl_to_msl(const char *glsl,
                        DioramaShaderStage stage,
                        char **out_msl,
                        char **out_error);

/// Release a string returned by this bridge.
void diorama_shader_free(char *value);

/// One-time global setup. Safe to call repeatedly; only the first call does anything.
void diorama_shader_bridge_initialize(void);

#ifdef __cplusplus
}
#endif

#endif
