#!/bin/bash

# Script to update port REF hash and version git-tree
# Usage: ./update_port_ref.sh <overlay_path> <port_name>
# Example: ./update_port_ref.sh /luksmap/Code/qvac-registry-vcpkg llama-cpp

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <overlay_path> <port_name>"
    echo "Example: $0 /luksmap/Code/qvac-registry-vcpkg llama-cpp"
    exit 1
fi

OVERLAY_PATH="$1"
PORT_NAME="$2"

# Validate overlay path
if [ ! -d "$OVERLAY_PATH" ]; then
    echo "Error: Overlay path does not exist: $OVERLAY_PATH"
    exit 1
fi

# Get current ref hash using git-log-h1 (or fallback)
if command -v git-log-h1 &> /dev/null || type git-log-h1 &> /dev/null; then
    NEW_REF=$(git-log-h1)
else
    # Fallback if git-log-h1 is not available
    NEW_REF=$(git log -1 --format=%H)
fi

if [ -z "$NEW_REF" ]; then
    echo "Error: Could not get current ref hash"
    exit 1
fi

echo "New REF hash: $NEW_REF"

# Navigate to overlay directory
cd "$OVERLAY_PATH"

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not a git repository: $OVERLAY_PATH"
    exit 1
fi

# Check if stg is initialized
if ! stg series > /dev/null 2>&1; then
    echo "Error: stg (stacked git) is not initialized or not available"
    exit 1
fi

# Go to previous commit (pop the top patch)
echo "Popping top patch to go to previous commit..."
stg pop

# Update portfile.cmake REF
PORTFILE="$OVERLAY_PATH/ports/$PORT_NAME/portfile.cmake"
if [ ! -f "$PORTFILE" ]; then
    echo "Error: Portfile not found: $PORTFILE"
    exit 1
fi

echo "Updating REF in $PORTFILE..."

# Extract current REF hash
CURRENT_REF=$(grep -E "^\s*REF\s+" "$PORTFILE" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")

if [ -z "$CURRENT_REF" ]; then
    echo "Error: Could not find REF in portfile"
    exit 1
fi

echo "Current REF: $CURRENT_REF"

# Replace REF hash in portfile
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS uses BSD sed
    sed -i '' "s/REF $CURRENT_REF/REF $NEW_REF/" "$PORTFILE"
else
    # Linux uses GNU sed
    sed -i "s/REF $CURRENT_REF/REF $NEW_REF/" "$PORTFILE"
fi

echo "Updated REF from $CURRENT_REF to $NEW_REF"

# Stage the portfile change
stg add "$PORTFILE"

# Refresh the stg patch
echo "Refreshing stg patch with portfile changes..."
stg refresh

stg push

# Update version file git-tree
# Determine version file path based on first letter of port name
FIRST_LETTER=$(echo "$PORT_NAME" | cut -c1 | tr '[:upper:]' '[:lower:]')
VERSION_FILE="$OVERLAY_PATH/versions/$FIRST_LETTER-/$PORT_NAME.json"

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: Version file not found: $VERSION_FILE"
    exit 1
fi

echo "Updating git-tree in $VERSION_FILE..."

# Get the git tree hash for the port directory
GIT_TREE=$(git rev-parse HEAD:ports/$PORT_NAME)

if [ -z "$GIT_TREE" ]; then
    echo "Error: Could not get git tree hash for ports/$PORT_NAME"
    exit 1
fi

echo "New git-tree: $GIT_TREE"

# Update the first version entry's git-tree
# Use Python or jq if available, otherwise use sed
if command -v python3 &> /dev/null; then
    python3 << EOF
import json
import sys

with open("$VERSION_FILE", 'r') as f:
    data = json.load(f)

if data['versions']:
    # Update the first version entry
    data['versions'][0]['git-tree'] = "$GIT_TREE"
    print(f"Updated git-tree for version {data['versions'][0]['version']} (port-version {data['versions'][0]['port-version']})")
else:
    print("Error: No versions found in version file")
    sys.exit(1)

with open("$VERSION_FILE", 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
EOF
elif command -v jq &> /dev/null; then
    # Use jq to update the first version's git-tree
    jq ".versions[0].git-tree = \"$GIT_TREE\"" "$VERSION_FILE" > "$VERSION_FILE.tmp" && mv "$VERSION_FILE.tmp" "$VERSION_FILE"
else
    echo "Error: Need python3 or jq to update JSON file"
    exit 1
fi

# Stage the version file change
stg add "$VERSION_FILE"

# Refresh the stg patch with version file update
echo "Refreshing stg patch with version file update..."
stg refresh

echo "Done! Updated REF to $NEW_REF and git-tree to $GIT_TREE"

# Push to remote
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
echo "Pushing to origin $BRANCH_NAME..."
git push origin HEAD:"$BRANCH_NAME" --force-with-lease
