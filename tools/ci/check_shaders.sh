#!/bin/bash
# Compiles every compute shader of the mod with glslang's HLSL front end (to SPIR-V, Vulkan 1.1) against stand-in engine
# headers (tools/ci/shader_stubs). It catches syntax and type errors before a release; it cannot prove a shader right in
# the game, whose own headers and compiler (DX12 / Vulkan) have the last word.
# Needs glslangValidator (apt: glslang-tools). Usage: bash tools/ci/check_shaders.sh [shader dir]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB="$ROOT/tools/ci/shader_stubs"
DIR="${1:-$(ls -d "$ROOT"/shaders/common/postFx/rainPuddles* | sort -V | tail -1)}"
ok=0; bad=0
for f in "$DIR"/*.cs.hlsl; do
  if out=$(glslangValidator -D -S comp -e main --target-env vulkan1.1 -I"$STUB" -I"$DIR" -o /dev/null "$f" 2>&1); then
    ok=$((ok + 1)); echo "ok   $(basename "$f")"
  else
    bad=$((bad + 1)); echo "FAIL $(basename "$f")"; echo "$out" | grep -E "ERROR|error" | head -10
  fi
done
echo "$ok compiled, $bad failed ($DIR)"
[ "$bad" -eq 0 ]
