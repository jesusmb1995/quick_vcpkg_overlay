#!/bin/bash

# Automate port version bumps in a vcpkg registry using stacked git (stg).
#
# Usage: ./new_port_version.sh [--hash <commit_hash>] <registry_path> <port_name> <new_version>
# Example: ./new_port_version.sh /luksmap/Code/qvac-registry-vcpkg qvac-lib-inference-addon-cpp 1.1.4
#          ./new_port_version.sh --hash 1458dd26 /luksmap/Code/qvac-registry-vcpkg qvac-lib-inference-addon-cpp 1.1.4
#
# Step 1 (stg patch): Updates portfile.cmake REF and vcpkg.json version
# Step 2 (stg patch): Adds version entry to versions/<x>-/<port>.json and updates baseline.json
#
# Options:
#   --hash <commit_hash>  Use this commit hash directly as the new REF instead of
#                         resolving from a git tag. Useful for monorepo ports where
#                         the REF is a repo-wide commit, not a per-package tag.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    echo "Usage: $0 [--hash <commit_hash>] <registry_path> <port_name> <new_version>"
    echo ""
    echo "Creates two stg patches in the registry:"
    echo "  1. Updates portfile.cmake (REF/SHA512) and vcpkg.json (version)"
    echo "  2. Adds entry to versions/<x>-/<port>.json and updates baseline.json"
    echo ""
    echo "Options:"
    echo "  --hash <commit_hash>  Use this commit hash as the new REF directly,"
    echo "                        skipping tag resolution. For monorepo ports where"
    echo "                        the commit is not tied to a per-package tag."
    echo ""
    echo "Arguments:"
    echo "  registry_path  Path to the vcpkg registry (e.g. /luksmap/Code/qvac-registry-vcpkg)"
    echo "  port_name      Name of the port (e.g. qvac-lib-inference-addon-cpp)"
    echo "  new_version    New version string (e.g. 1.1.4)"
    echo ""
    echo "Examples:"
    echo "  $0 /luksmap/Code/qvac-registry-vcpkg qvac-fabric 7248.1.4"
    echo "  $0 --hash 1458dd269bf8fda8fd7a600389bde96c0e6274c6 /luksmap/Code/qvac-registry-vcpkg qvac-lib-inference-addon-cpp 1.1.4"
}

EXPLICIT_HASH=""

if [ "$1" = "--hash" ]; then
    if [ $# -ne 5 ]; then
        usage
        exit 1
    fi
    EXPLICIT_HASH="$2"
    shift 2
elif [ $# -ne 3 ]; then
    usage
    exit 1
fi

REGISTRY_PATH="$1"
PORT_NAME="$2"
NEW_VERSION="${3#v}"

PORTFILE="$REGISTRY_PATH/ports/$PORT_NAME/portfile.cmake"
VCPKG_JSON="$REGISTRY_PATH/ports/$PORT_NAME/vcpkg.json"
FIRST_LETTER=$(echo "$PORT_NAME" | cut -c1 | tr '[:upper:]' '[:lower:]')
VERSION_FILE="$REGISTRY_PATH/versions/$FIRST_LETTER-/$PORT_NAME.json"
BASELINE_FILE="$REGISTRY_PATH/versions/baseline.json"

# ---------- Validation ----------

if [ ! -d "$REGISTRY_PATH" ]; then
    err "Registry path does not exist: $REGISTRY_PATH"
    exit 1
fi

if [ ! -f "$PORTFILE" ]; then
    err "Portfile not found: $PORTFILE"
    exit 1
fi

if [ ! -f "$VCPKG_JSON" ]; then
    err "vcpkg.json not found: $VCPKG_JSON"
    exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
    err "Version file not found: $VERSION_FILE"
    exit 1
fi

if [ ! -f "$BASELINE_FILE" ]; then
    err "Baseline file not found: $BASELINE_FILE"
    exit 1
fi

cd "$REGISTRY_PATH"

if ! git rev-parse --git-dir > /dev/null 2>&1; then
    err "Not a git repository: $REGISTRY_PATH"
    exit 1
fi

if ! command -v stg &> /dev/null; then
    err "stg (stacked git) is not installed"
    exit 1
fi

if ! stg series > /dev/null 2>&1; then
    err "stg is not initialized in this repo. Run 'stg init' first."
    exit 1
fi

# ---------- Detect source type ----------

resolve_vcpkg_from_git_ref() {
    local url_raw
    url_raw=$(grep -A 20 'vcpkg_from_git(' "$PORTFILE" | grep -m1 'URL' | sed 's/.*URL\s*//' | tr -d '"' | tr -d "'" | sed 's/)$//' | xargs)

    # Resolve CMake variable references like ${SOME_VAR}
    if [[ "$url_raw" == \$\{* ]] || [[ "$url_raw" == *\$\{* ]]; then
        local var_name
        var_name=$(echo "$url_raw" | grep -oP '\$\{\K[A-Za-z_]+')
        url_raw=$(grep "set($var_name" "$PORTFILE" | grep -oP '"[^"]*"' | tr -d '"')
    fi

    if [ -z "$url_raw" ]; then
        err "Could not extract git URL from portfile"
        exit 1
    fi

    SOURCE_URL="$url_raw"

    # Extract current REF
    local ref_raw
    ref_raw=$(grep -A 20 'vcpkg_from_git(' "$PORTFILE" | grep -m1 'REF' | sed 's/.*REF\s*//' | tr -d '"' | tr -d "'" | sed 's/)$//' | xargs)

    # If REF is a variable, skip REF update
    if [[ "$ref_raw" == \$\{* ]] || [[ "$ref_raw" == *\$\{* ]]; then
        warn "REF uses a variable ($ref_raw) — skipping REF update, only updating vcpkg.json"
        SKIP_REF_UPDATE=true
        return
    fi

    CURRENT_REF="$ref_raw"

    info "Source URL: $SOURCE_URL"
    info "Current REF: $CURRENT_REF"

    if [ -n "$EXPLICIT_HASH" ]; then
        NEW_REF="$EXPLICIT_HASH"
        info "Using explicit hash: $NEW_REF"
    else
        info "Resolving tag v${NEW_VERSION} to commit hash..."

        NEW_REF=$(git ls-remote --tags "$SOURCE_URL" "refs/tags/v${NEW_VERSION}" 2>/dev/null | awk '{print $1}')
        if [ -z "$NEW_REF" ]; then
            info "Tag v${NEW_VERSION} not found, trying ${NEW_VERSION}..."
            NEW_REF=$(git ls-remote --tags "$SOURCE_URL" "refs/tags/${NEW_VERSION}" 2>/dev/null | awk '{print $1}')
        fi

        if [ -z "$NEW_REF" ]; then
            err "Could not resolve tag for version ${NEW_VERSION} in $SOURCE_URL"
            echo "  Available tags:"
            git ls-remote --tags "$SOURCE_URL" 2>/dev/null | tail -5
            exit 1
        fi

        info "Resolved to REF: $NEW_REF"
    fi
    SKIP_REF_UPDATE=false
}

resolve_vcpkg_from_github_sha() {
    GITHUB_REPO=$(grep -A 20 'vcpkg_from_github(' "$PORTFILE" | grep -m1 'REPO' | sed 's/.*REPO\s*//' | xargs)

    if [ -z "$GITHUB_REPO" ]; then
        err "Could not extract REPO from portfile"
        exit 1
    fi

    info "GitHub repo: $GITHUB_REPO"

    # Check if REF uses ${VERSION} — if so we only need to update SHA512
    if grep -A 20 'vcpkg_from_github(' "$PORTFILE" | grep -q 'REF.*\${VERSION}'; then
        info "REF uses \${VERSION} — version comes from vcpkg.json, updating SHA512 only"
    fi

    CURRENT_SHA512=$(grep -A 20 'vcpkg_from_github(' "$PORTFILE" | grep -m1 'SHA512' | sed 's/.*SHA512\s*//' | xargs)

    info "Downloading tarball to compute SHA512..."
    local tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/tags/v${NEW_VERSION}.tar.gz"
    local tmp_file
    tmp_file=$(mktemp)

    if ! curl -fsSL "$tarball_url" -o "$tmp_file" 2>/dev/null; then
        info "Tag v${NEW_VERSION} not found, trying ${NEW_VERSION}..."
        tarball_url="https://github.com/${GITHUB_REPO}/archive/refs/tags/${NEW_VERSION}.tar.gz"
        if ! curl -fsSL "$tarball_url" -o "$tmp_file" 2>/dev/null; then
            rm -f "$tmp_file"
            err "Could not download tarball from $tarball_url"
            exit 1
        fi
    fi

    NEW_SHA512=$(sha512sum "$tmp_file" | awk '{print $1}')
    rm -f "$tmp_file"

    info "New SHA512: $NEW_SHA512"
    SKIP_REF_UPDATE=true  # REF is v${VERSION}, handled by vcpkg.json version
}

SOURCE_TYPE=""
SKIP_REF_UPDATE=false

if grep -q 'vcpkg_from_github(' "$PORTFILE"; then
    SOURCE_TYPE="github"
    info "Detected source type: vcpkg_from_github"
    resolve_vcpkg_from_github_sha
elif grep -q 'vcpkg_from_git(' "$PORTFILE"; then
    SOURCE_TYPE="git"
    info "Detected source type: vcpkg_from_git"
    resolve_vcpkg_from_git_ref
else
    err "Could not detect vcpkg_from_git or vcpkg_from_github in portfile"
    exit 1
fi

# ============================================================
# STEP 1: Update portfile.cmake and vcpkg.json
# ============================================================

echo ""
info "===== Step 1: Update portfile + vcpkg.json ====="

PATCH_NAME="portfile-${PORT_NAME}-${NEW_VERSION}"
info "Creating stg patch: $PATCH_NAME"
stg new "$PATCH_NAME" -m "Update ${PORT_NAME} portfile to ${NEW_VERSION}"

# Update portfile.cmake
if [ "$SOURCE_TYPE" = "github" ]; then
    if [ -n "$CURRENT_SHA512" ] && [ -n "$NEW_SHA512" ]; then
        sed -i "s|SHA512 ${CURRENT_SHA512}|SHA512 ${NEW_SHA512}|" "$PORTFILE"
        ok "Updated SHA512 in portfile.cmake"
    fi
elif [ "$SOURCE_TYPE" = "git" ] && [ "$SKIP_REF_UPDATE" = "false" ]; then
    sed -i "s|REF ${CURRENT_REF}|REF ${NEW_REF}|" "$PORTFILE"
    ok "Updated REF from ${CURRENT_REF} to ${NEW_REF}"
fi

# Update vcpkg.json version
python3 << PYEOF
import json

with open("$VCPKG_JSON", "r") as f:
    data = json.load(f)

old_version = data.get("version", "(none)")
data["version"] = "$NEW_VERSION"

with open("$VCPKG_JSON", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"Updated vcpkg.json version: {old_version} -> $NEW_VERSION")
PYEOF

stg add "$PORTFILE" "$VCPKG_JSON"
stg refresh
ok "Step 1 complete — portfile + vcpkg.json updated"

# ============================================================
# STEP 2: Update versions file and baseline
# ============================================================

echo ""
info "===== Step 2: Update versions + baseline ====="

PATCH_NAME="versions-${PORT_NAME}-${NEW_VERSION}"
info "Creating stg patch: $PATCH_NAME"
stg new "$PATCH_NAME" -m "Update ${PORT_NAME} versions to ${NEW_VERSION}"

# Compute git-tree for the port directory from the current commit
GIT_TREE=$(git rev-parse "HEAD:ports/$PORT_NAME")
info "git-tree for ports/$PORT_NAME: $GIT_TREE"

# Ensure versions subdirectory exists
VERSION_DIR="$REGISTRY_PATH/versions/$FIRST_LETTER-"
mkdir -p "$VERSION_DIR"

# Add new version entry and update baseline
python3 << PYEOF
import json

# --- Update versions/<x>-/<port>.json ---
with open("$VERSION_FILE", "r") as f:
    vdata = json.load(f)

new_entry = {
    "git-tree": "$GIT_TREE",
    "version": "$NEW_VERSION",
    "port-version": 0
}

# Prepend new version at the top
vdata["versions"].insert(0, new_entry)

with open("$VERSION_FILE", "w") as f:
    json.dump(vdata, f, indent=2)
    f.write("\n")

print(f"Added version entry: {new_entry}")

# --- Update baseline.json ---
with open("$BASELINE_FILE", "r") as f:
    bdata = json.load(f)

old_baseline = bdata["default"].get("$PORT_NAME", {}).get("baseline", "(none)")
bdata["default"]["$PORT_NAME"] = {
    "baseline": "$NEW_VERSION",
    "port-version": 0
}

with open("$BASELINE_FILE", "w") as f:
    json.dump(bdata, f, indent=2)
    f.write("\n")

print(f"Updated baseline: {old_baseline} -> $NEW_VERSION")
PYEOF

stg add "$VERSION_FILE" "$BASELINE_FILE"
stg refresh
ok "Step 2 complete — versions + baseline updated"

echo ""
ok "All done! Created 2 stg patches for ${PORT_NAME} ${NEW_VERSION}"
echo ""
info "Patches:"
stg series | tail -5
echo ""
info "Next steps:"
echo "  - Review patches:  stg show"
echo "  - Push to remote:  git push origin HEAD:<branch> --force-with-lease"
echo "  - Squash patches:  stg squash -n <name> -- <patch1> <patch2>"
