#!/bin/bash
# Xcode Cloud runs this before each xcodebuild action (build, test, archive).
# It stamps the Xcode Cloud build number into the generated project, so every bundle
# (the app, the widgets, the watch app and its complications) carries the same
# CFBundleVersion: their Info.plists read it from $(CURRENT_PROJECT_VERSION) (project.yml).
# The marketing version stays MARKETING_VERSION in project.yml.
set -euo pipefail

if [[ -z "${CI_BUILD_NUMBER:-}" ]]; then
  echo "Zimam: CI_BUILD_NUMBER is not set; keeping CURRENT_PROJECT_VERSION from project.yml"
  exit 0
fi
if [[ ! "${CI_BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "error: CI_BUILD_NUMBER is not a whole number: ${CI_BUILD_NUMBER}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PBXPROJ="${SCRIPT_DIR}/../Zimam.xcodeproj/project.pbxproj"
if [[ ! -f "${PBXPROJ}" ]]; then
  echo "error: ${PBXPROJ} is missing; ci_post_clone.sh should have generated it." >&2
  exit 1
fi

# XcodeGen writes the project-level setting once per configuration (Debug, Release).
sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[^;]+;/\1${CI_BUILD_NUMBER};/g" "${PBXPROJ}"
if ! grep -q "CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};" "${PBXPROJ}"; then
  echo "error: could not set CURRENT_PROJECT_VERSION in ${PBXPROJ}." >&2
  exit 1
fi
echo "Zimam: CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER} (action: ${CI_XCODEBUILD_ACTION:-unknown})"
