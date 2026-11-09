#!/usr/bin/env bash
# A glslc command line, compiled with glslang (glslangValidator) instead: the drop-in for glslc in llama.cpp's Vulkan
# build (vulkan-shaders-gen runs it per shader variant, and tests/llamacpp/vulkan/build.sh runs it for the extension
# probes). Accepts the options that build uses: -fshader-stage=compute, --target-env=..., -D..., -o FILE, -O (spirv-opt
# -O, as glslc runs it), -MD -MF FILE (a dependency file), and one source file. Exit status and the "extension not
# supported" message are glslc's, so the probes read them the same way.
#
# glslang does not enable GL_GOOGLE_include_directive by default, and glslc does: the preamble below turns it on, so the
# shaders' #include lines work without changing their sources.
set -u
env=vulkan1.2 out= src= dep= opt=0 defs=()
while [ $# -gt 0 ]; do
  case $1 in
    -fshader-stage=*) ;;
    --target-env=*) env=${1#--target-env=} ;;
    -D*) defs+=("$1") ;;
    -O) opt=1 ;;
    -MD) ;;
    -MF) dep=$2; shift ;;
    -o) out=$2; shift ;;
    -*) echo "glslc-glslang: unsupported option $1" >&2; exit 2 ;;
    *) src=$1 ;;
  esac
  shift
done
[ -n "$src" ] || { echo "glslc-glslang: no source file" >&2; exit 2; }
[ -n "$out" ] || out=a.spv
glslangValidator -V -S comp --target-env "$env" "${defs[@]}" \
  -P'#extension GL_GOOGLE_include_directive : enable' "$src" -o "$out" || exit $?
if [ "$opt" = 1 ]; then
  spirv-opt -O "$out" -o "$out.opt" && mv "$out.opt" "$out" || { rm -f "$out"; exit 1; }
fi
[ -n "$dep" ] && printf '%s: %s\n' "$out" "$src" > "$dep"
exit 0
