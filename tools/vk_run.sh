#!/bin/sh
# Run a binary from the Vulkan build tree, making sure ggml.dll is present first.
#
# The tree drops ggml.dll from bin/Release whenever another target is built - building
# `llama` alone is enough to remove it - and the resulting failure is a bare
# STATUS_DLL_NOT_FOUND with no message. Rebuilding ggml last costs a second when it is
# already current and saves a confusing crash when it is not.
set -e
ROOT=/d/MemeX/src/ik_llama.cpp
cmake --build "$ROOT/build-vk" --config Release --target ggml >/dev/null 2>&1 || true
if [ ! -f "$ROOT/build-vk/bin/Release/ggml.dll" ]; then
    echo "ggml.dll так и не появился" >&2
    exit 1
fi
exec "$ROOT/build-vk/bin/Release/$@"
