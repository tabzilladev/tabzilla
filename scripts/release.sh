#!/usr/bin/env bash
# release.sh — tag and push the current version to trigger the CI release workflow
# Usage: scripts/release.sh [--force]

set -euo pipefail

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "Usage: $0 [--force]" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_SWIFT="$REPO_ROOT/Sources/CLI.swift"

VERSION="$(grep -o 'version: "[^"]*"' "$CLI_SWIFT" | grep -o '"[^"]*"' | tr -d '"')"
if [[ -z "$VERSION" ]]; then
  echo "Error: could not read version from $CLI_SWIFT" >&2
  exit 1
fi

TAG="v$VERSION"

LOCAL_EXISTS=0
REMOTE_EXISTS=0
git -C "$REPO_ROOT" rev-parse "$TAG" >/dev/null 2>&1 && LOCAL_EXISTS=1
git -C "$REPO_ROOT" ls-remote --tags origin "$TAG" | grep -q "$TAG" && REMOTE_EXISTS=1

if [[ $LOCAL_EXISTS -eq 1 || $REMOTE_EXISTS -eq 1 ]]; then
  if [[ $FORCE -eq 0 ]]; then
    echo "Error: tag $TAG already exists. Use --force to re-tag." >&2
    exit 1
  fi
  echo "Removing existing tag $TAG..."
  [[ $LOCAL_EXISTS -eq 1 ]] && git -C "$REPO_ROOT" tag -d "$TAG"
  [[ $REMOTE_EXISTS -eq 1 ]] && git -C "$REPO_ROOT" push origin ":refs/tags/$TAG"
fi

REPO_URL="$(gh repo view --json url -q .url)"

echo "Tagging $TAG..."
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin "$TAG"
echo "Pushed $TAG — CI release workflow triggered"
echo "View on GitHub: $REPO_URL/actions"
