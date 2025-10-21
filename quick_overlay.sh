#!/bin/bash

source "$HOME/.aliases"

# Store the directory where this script is located (tool dir)
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_FOLDER=$1

CURRENT_PWD=$(pwd)

REF_HASH=""
PROJECT_NAME=""
VERSION=""
ORIGIN=""

cd "${REPO_FOLDER}" || exit 1
REF_HASH=$(git-log-h1)
PROJECT_NAME=$(grep -oP 'project\(\s*\K[^\s]+' CMakeLists.txt)
VERSION=$(grep -A2 '^project(' CMakeLists.txt | grep -oP 'VERSION\s+\K[^\s]+')
# ORIGIN=$(git config --get remote.origin.url)
ORIGIN="${REPO_FOLDER}"
cd "${CURRENT_PWD}" || exit 1

source "${TOOL_DIR}/venv/bin/activate"
mkdir -p "${CURRENT_PWD}/vcpkg/ports/${PROJECT_NAME}"
jinja2 "${TOOL_DIR}/portfile.cmake.j2" -D ref="${REF_HASH}" -D origin="${ORIGIN}" > "${CURRENT_PWD}/vcpkg/ports/${PROJECT_NAME}/portfile.cmake"
jinja2 "${TOOL_DIR}/vcpkg.json.j2" -D name="${PROJECT_NAME}" -D version="${VERSION}" > "${CURRENT_PWD}/vcpkg/ports/${PROJECT_NAME}/vcpkg.json"
