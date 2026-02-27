#!/bin/bash
# Download the Metal compiler plugin source files from zeroxjf's blog.
# Run this on your Mac (not in a restricted environment).
#
# These files implement the Metal compiler plugin for the paravirtualized GPU
# in the iOS VM (AppleParavirtGPUMetalIOGPUFamily.bundle).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="https://zeroxjf.github.io/blog/assets/metal-patch"

echo "Downloading Metal compiler plugin sources..."

curl -fSL -o "$SCRIPT_DIR/main.mm" "$BASE_URL/main.mm"
echo "  Downloaded main.mm"

curl -fSL -o "$SCRIPT_DIR/build.sh" "$BASE_URL/build.sh"
chmod +x "$SCRIPT_DIR/build.sh"
echo "  Downloaded build.sh"

echo "Done. Now run: ./build.sh"
