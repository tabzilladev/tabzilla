#!/usr/bin/env bash
# set-version.sh — patch all version locations from a single semver argument
# Usage: scripts/set-version.sh 1.2.3

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  echo "  Example: $0 1.2.3" >&2
  exit 1
fi

VERSION="$1"

# Validate semver format (X.Y.Z)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be in X.Y.Z format (got '$VERSION')" >&2
  exit 1
fi

PATCH="${VERSION##*.}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CLI_SWIFT="$REPO_ROOT/Sources/CLI.swift"
PBXPROJ="$REPO_ROOT/Tabzilla.xcodeproj/project.pbxproj"

echo "Setting version to $VERSION..."

# Patch CLI.swift: version: "X.Y.Z"
sed -i '' "s/version: \"[^\"]*\"/version: \"$VERSION\"/" "$CLI_SWIFT"
echo "  CLI.swift: version = $VERSION"

# Patch CURRENT_PROJECT_VERSION in project.pbxproj
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $PATCH/g" "$PBXPROJ"
echo "  project.pbxproj: CURRENT_PROJECT_VERSION = $PATCH"

# Patch MARKETING_VERSION in project.pbxproj
sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/g" "$PBXPROJ"
echo "  project.pbxproj: MARKETING_VERSION = $VERSION"

echo "Done."
