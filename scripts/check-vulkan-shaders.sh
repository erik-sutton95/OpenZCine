#!/usr/bin/env bash
# SPIR-V is now derived from shared GLSL by the native Vulkan CMake build.
# Keep this entry point for the shared renderer synchronization regression.
# The complete Android consumer build also compiles both Bitmap shaders.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$repo_root/../OpenCine/scripts/android-vulkan-sync-test.sh"
