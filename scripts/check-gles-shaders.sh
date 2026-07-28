#!/usr/bin/env bash
# Guards the GLES2 shaders against GLSL ES 1.00 reserved words used as identifiers.
#
# Nothing in the build compiles these: the .glsl files under app/src/main/assets/shaders/ are
# loaded and compiled by the DRIVER at runtime, so a syntax error ships with a green
# `android-check` and only shows up on a device. Worse, the live surface catches the compile
# failure and falls back to the plain feed, so it reads as "the LUT and peaking silently stopped
# working" rather than as a build problem. That cost a device round trip once already, on
# `packed` — reserved in GLSL ES 1.00 and a perfectly ordinary variable name anywhere else.
#
# This is a LINT, not a compiler: it catches the reserved-identifier class only. A real gate
# wants `glslangValidator` (glslc cannot do `#version 100` — SPIR-V needs ES 310+), which would
# mean a new toolchain dependency here and in CI. Until then, this covers the trap that actually
# fired.
set -euo pipefail

cd "$(dirname "$0")/.."

SHADER_DIR="Apps/Android/app/src/main/assets/shaders"

# GLSL ES 1.00 §3.7, "keywords reserved for future use". Words that are already illegal as
# identifiers in any C-like language (if/for/return...) are omitted: the compiler and review
# catch those, and they never read as innocent names.
RESERVED='asm|class|union|enum|typedef|template|this|packed|goto|switch|default|inline|noinline|volatile|public|static|extern|external|interface|flat|long|short|double|half|fixed|unsigned|superp|input|output|hvec2|hvec3|hvec4|dvec2|dvec3|dvec4|fvec2|fvec3|fvec4|sampler3D|sampler1D|sampler1DShadow|sampler2DShadow|sampler2DRect|sampler3DRect|sampler2DRectShadow|sizeof|cast|namespace|using'

status=0
shopt -s nullglob
for shader in "$SHADER_DIR"/*.glsl; do
    # Strip // and /* */ comments so prose about a reserved word is not a finding.
    stripped=$(
        sed -e 's|//.*$||' "$shader" | sed -e 's|/\*[^*]*\*/||g'
    )
    while IFS=: read -r line text; do
        [ -n "${line:-}" ] || continue
        echo "check-gles-shaders: $shader:$line reserved GLSL ES 1.00 word: ${text}" >&2
        status=1
    done < <(
        printf '%s\n' "$stripped" \
            | grep -nEo "\b($RESERVED)\b" \
            | sort -u -t: -k1,1n
    )
done

if [ "$status" -ne 0 ]; then
    echo "check-gles-shaders: rename the identifiers above — the driver rejects the whole shader," >&2
    echo "and the live surface then silently renders the plain feed." >&2
    exit 1
fi

echo "check-gles-shaders: no reserved GLSL ES 1.00 identifiers"
