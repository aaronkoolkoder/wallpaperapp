#!/bin/bash
# Fetches and builds glslang and SPIRV-Cross as static libraries.
#
#   Scripts/vendor-shader-tools.sh
#
# Pinned to tags rather than tracking a branch: a shader compiler changing under the project
# would show up as wallpapers rendering differently with no commit to explain it. Both are
# permissively licensed (glslang BSD-3/Apache-2, SPIRV-Cross Apache-2) and therefore App Store
# compatible — see THIRD_PARTY.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
PREFIX="$VENDOR/install"

GLSLANG_TAG="15.1.0"
SPIRV_CROSS_TAG="vulkan-sdk-1.3.296.0"

mkdir -p "$VENDOR"
cd "$VENDOR"

fetch() {
    local name="$1" url="$2" tag="$3"
    if [ -d "$name/.git" ]; then
        echo "  $name already fetched"
        return
    fi
    echo "  fetching $name @ $tag"
    git clone --quiet --depth 1 --branch "$tag" "$url" "$name"
    # Record exactly what landed, so a later build can be shown to match this one.
    (cd "$name" && git rev-parse HEAD > "$VENDOR/$name.sha")
}

echo "fetching sources…"
fetch glslang https://github.com/KhronosGroup/glslang.git "$GLSLANG_TAG"
fetch SPIRV-Cross https://github.com/KhronosGroup/SPIRV-Cross.git "$SPIRV_CROSS_TAG"

echo "verifying…"
"$ROOT/Scripts/verify-dependency.sh" "$VENDOR/glslang" || true
"$ROOT/Scripts/verify-dependency.sh" "$VENDOR/SPIRV-Cross" || true

build() {
    local name="$1"; shift
    if [ -f "$PREFIX/.built-$name" ]; then
        echo "  $name already built"
        return
    fi
    echo "  building $name"
    cmake -S "$VENDOR/$name" -B "$VENDOR/$name/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
        -DBUILD_SHARED_LIBS=OFF \
        "$@" >/dev/null
    cmake --build "$VENDOR/$name/build" --target install >/dev/null
    mkdir -p "$PREFIX"
    touch "$PREFIX/.built-$name"
}

echo "building…"
# glslang's own dependency fetch is skipped: SPIR-V Tools is only needed for optimisation
# passes, and this pipeline transpiles rather than optimises.
build glslang \
    -DENABLE_OPT=OFF \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DGLSLANG_TESTS=OFF \
    -DENABLE_CTEST=OFF

build SPIRV-Cross \
    -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF \
    -DSPIRV_CROSS_ENABLE_GLSL=ON \
    -DSPIRV_CROSS_ENABLE_MSL=ON \
    -DSPIRV_CROSS_ENABLE_HLSL=OFF \
    -DSPIRV_CROSS_ENABLE_CPP=OFF \
    -DSPIRV_CROSS_ENABLE_REFLECT=OFF \
    -DSPIRV_CROSS_ENABLE_C_API=OFF \
    -DSPIRV_CROSS_ENABLE_UTIL=ON

# Stage headers inside the SwiftPM target.
#
# SwiftPM compiles with a working directory that is not the package root, so a relative
# -I pointing at Vendor/ never resolves, and an absolute one is not portable across machines.
# `.headerSearchPath` is relative to the target, so the headers have to live there — but not
# under include/, where SwiftPM's umbrella-header rule forbids sibling directories.
STAGED="$ROOT/Sources/ShaderBridge/vendor"
echo "staging headers into the target…"
rm -rf "$STAGED"
mkdir -p "$STAGED"
cp -R "$PREFIX/include/glslang" "$STAGED/glslang"
cp -R "$PREFIX/include/spirv_cross" "$STAGED/spirv_cross"
# SPIRV-Cross includes its own headers unprefixed, so they need to sit at the search root too.
cp "$PREFIX/include/spirv_cross/"*.hpp "$STAGED/" 2>/dev/null || true
cp "$PREFIX/include/spirv_cross/"*.h "$STAGED/" 2>/dev/null || true

echo
echo "installed to $PREFIX"
ls "$PREFIX/lib" 2>/dev/null | sed 's/^/  /' | head -20
