#!/bin/bash

# Creates an overlay port by copying from an existing registry and converting
# vcpkg_from_github to vcpkg_from_git with a specific branch's HEAD commit.
#
# Usage: ./overlay_from_registry.sh <registry_path> <package_name> <git_url> <branch_name>
# Example: ./overlay_from_registry.sh /luksmap/Code/qvac-registry mylib https://gitlab.com/org/mylib.git main

set -e

if [ $# -ne 4 ]; then
    echo "Usage: $0 <registry_path> <package_name> <git_url> <branch_name>"
    echo "Example: $0 /luksmap/Code/qvac-registry mylib https://gitlab.com/org/mylib.git main"
    exit 1
fi

REGISTRY_PATH="$1"
PACKAGE_NAME="$2"
GIT_URL="$3"
BRANCH_NAME="$4"

CURRENT_PWD=$(pwd)
SOURCE_PORT="$REGISTRY_PATH/ports/$PACKAGE_NAME"
DEST_PORT="$CURRENT_PWD/vcpkg/ports/$PACKAGE_NAME"

if [ ! -d "$SOURCE_PORT" ]; then
    echo "Error: Source port not found: $SOURCE_PORT"
    exit 1
fi

# Resolve the HEAD commit hash of the branch
echo "Resolving HEAD of branch '$BRANCH_NAME' from $GIT_URL ..."
REF_HASH=$(git ls-remote "$GIT_URL" "refs/heads/$BRANCH_NAME" | awk '{print $1}')

if [ -z "$REF_HASH" ]; then
    echo "Error: Could not resolve branch '$BRANCH_NAME' from $GIT_URL"
    exit 1
fi

echo "Resolved REF: $REF_HASH"

# Copy port folder
mkdir -p "$DEST_PORT"
cp -r "$SOURCE_PORT"/* "$DEST_PORT"/
echo "Copied port from $SOURCE_PORT to $DEST_PORT"

PORTFILE="$DEST_PORT/portfile.cmake"
if [ ! -f "$PORTFILE" ]; then
    echo "Error: portfile.cmake not found in copied port"
    exit 1
fi

# Replace vcpkg_from_github with vcpkg_from_git and rewrite parameters
python3 - "$PORTFILE" "$GIT_URL" "$REF_HASH" << 'PYEOF'
import re
import sys

portfile = sys.argv[1]
git_url = sys.argv[2]
ref_hash = sys.argv[3]

with open(portfile, 'r') as f:
    content = f.read()

# Match the entire vcpkg_from_github(...) block
pattern = r'vcpkg_from_github\s*\([^)]*\)'
match = re.search(pattern, content, re.DOTALL)

if not match:
    print("Warning: vcpkg_from_github block not found; writing vcpkg_from_git block at the top")
    replacement = (
        f'vcpkg_from_git(\n'
        f'  OUT_SOURCE_PATH SOURCE_PATH\n'
        f'  URL {git_url}\n'
        f'  REF {ref_hash}\n'
        f')'
    )
    content = replacement + '\n\n' + content
else:
    replacement = (
        f'vcpkg_from_git(\n'
        f'  OUT_SOURCE_PATH SOURCE_PATH\n'
        f'  URL {git_url}\n'
        f'  REF {ref_hash}\n'
        f')'
    )
    content = content[:match.start()] + replacement + content[match.end():]

with open(portfile, 'w') as f:
    f.write(content)

print(f"Portfile updated: vcpkg_from_git with URL={git_url} REF={ref_hash}")
PYEOF

echo "Done! Overlay port created at $DEST_PORT"
