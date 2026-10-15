#!/bin/bash
# Xcode Cloud runs this right after cloning the repository (it looks for ci_scripts/ next to
# the project, and the project lives in apple/). Zimam.xcodeproj is generated from
# apple/project.yml and is not in the repository, so this script:
#   1. downloads a pinned XcodeGen release and checks its SHA-256,
#   2. generates Zimam.xcodeproj (with its shared «Zimam» scheme) in apple/,
#   3. gives the project a Package.resolved: Xcode Cloud builds with automatic package
#      resolution turned off, and fails without one.
# Steps and troubleshooting: docs/release.md.
set -euo pipefail

# To update XcodeGen: change both values together. The checksum is of the release's
# xcodegen.zip (shasum -a 256 xcodegen.zip).
XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="$(mktemp -d)"
trap 'rm -rf "${TOOLS_DIR}"' EXIT

echo "Zimam: installing XcodeGen ${XCODEGEN_VERSION}"
curl --fail --silent --show-error --location --retry 3 --retry-delay 5 \
  --output "${TOOLS_DIR}/xcodegen.zip" "${XCODEGEN_URL}"
echo "${XCODEGEN_SHA256}  ${TOOLS_DIR}/xcodegen.zip" | shasum -a 256 --check --status || {
  echo "error: xcodegen.zip does not match the pinned SHA-256; refusing to run it." >&2
  exit 1
}
unzip -q "${TOOLS_DIR}/xcodegen.zip" -d "${TOOLS_DIR}"
# Run from the unzipped folder: the binary finds its SettingPresets in ../share/xcodegen.
XCODEGEN="${TOOLS_DIR}/xcodegen/bin/xcodegen"
"${XCODEGEN}" --version

echo "Zimam: generating Zimam.xcodeproj from project.yml"
cd "${APPLE_DIR}"
"${XCODEGEN}" generate --spec project.yml

SCHEME="Zimam.xcodeproj/xcshareddata/xcschemes/Zimam.xcscheme"
if [[ ! -f "${SCHEME}" ]]; then
  echo "error: the shared scheme «Zimam» was not generated (${SCHEME})." >&2
  exit 1
fi

RESOLVED_DIR="Zimam.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
if [[ -f "Package.resolved" ]]; then
  # The pinned package versions, committed in apple/ (docs/release.md).
  mkdir -p "${RESOLVED_DIR}"
  cp "Package.resolved" "${RESOLVED_DIR}/Package.resolved"
  echo "Zimam: using the committed apple/Package.resolved"
else
  echo "warning: apple/Package.resolved is not committed; resolving packages to the newest allowed versions." >&2
  xcodebuild -resolvePackageDependencies -project Zimam.xcodeproj -scheme Zimam
fi

echo "Zimam: project ready"
