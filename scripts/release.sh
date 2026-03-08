#!/usr/bin/env bash
# release.sh — validate, bump, commit, tag, and push
# Usage: scripts/release.sh <version> [--dry-run] [--force]

set -euo pipefail

VERSION=""
DRY_RUN=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --force)    FORCE=1 ;;
    -*)         echo "Usage: $0 <version> [--dry-run] [--force]" >&2; exit 1 ;;
    *)
      if [[ -z "$VERSION" ]]; then
        VERSION="$arg"
      else
        echo "Usage: $0 <version> [--dry-run] [--force]" >&2; exit 1
      fi
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--dry-run] [--force]" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_SWIFT="$REPO_ROOT/Sources/CLI.swift"
PBXPROJ="$REPO_ROOT/Tabzilla.xcodeproj/project.pbxproj"

# --- Precondition: valid semver ---
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be in X.Y.Z format (got '$VERSION')" >&2
  exit 1
fi

TAG="v$VERSION"

# --- Precondition: on main branch ---
CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "Error: must be on main branch (currently on '$CURRENT_BRANCH')" >&2
  exit 1
fi

# --- Precondition: clean working tree ---
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "Error: working tree has uncommitted changes" >&2
  exit 1
fi
if [[ -n "$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)" ]]; then
  echo "Error: working tree has untracked files" >&2
  exit 1
fi

# --- Read current version ---
CURRENT_VERSION="$(grep -o 'appVersion = "[^"]*"' "$CLI_SWIFT" | grep -o '"[^"]*"' | tr -d '"')"
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "Error: could not read current version from $CLI_SWIFT" >&2
  exit 1
fi

# --- Precondition: version differs (unless --force) ---
VERSION_CHANGED=1
if [[ "$VERSION" == "$CURRENT_VERSION" ]]; then
  if [[ $FORCE -eq 0 ]]; then
    echo "Error: version is already $VERSION. Use --force to re-release." >&2
    exit 1
  fi
  VERSION_CHANGED=0
fi

# --- Check existing tags ---
LOCAL_TAG_EXISTS=0
REMOTE_TAG_EXISTS=0
git -C "$REPO_ROOT" rev-parse "$TAG" >/dev/null 2>&1 && LOCAL_TAG_EXISTS=1
git -C "$REPO_ROOT" ls-remote --tags origin "$TAG" | grep -q "$TAG" 2>/dev/null && REMOTE_TAG_EXISTS=1

if [[ $LOCAL_TAG_EXISTS -eq 1 || $REMOTE_TAG_EXISTS -eq 1 ]]; then
  if [[ $FORCE -eq 0 ]]; then
    echo "Error: tag $TAG already exists. Use --force to re-release." >&2
    exit 1
  fi
fi

# --- Dry-run output ---
if [[ $DRY_RUN -eq 1 ]]; then
  if [[ $FORCE -eq 1 && $VERSION_CHANGED -eq 0 ]]; then
    echo "Dry run: re-release $VERSION (--force)"
    echo ""
    echo "  Local:"
    echo "    1. Version already $VERSION, skip version bump"
    echo "    2. Delete existing tag $TAG (local and remote)"
    echo "    3. Create tag: $TAG"
    echo "    4. Push tag to origin"
  else
    echo "Dry run: release $VERSION (currently $CURRENT_VERSION)"
    echo ""
    echo "  Local:"
    echo "    1. Patch version: $CURRENT_VERSION → $VERSION"
    echo "       - Sources/CLI.swift"
    echo "       - Tabzilla.xcodeproj/project.pbxproj"
    echo "    2. Commit: \"$VERSION\""
    echo "    3. Create tag: $TAG"
    echo "    4. Push tag to origin"
  fi
  echo ""
  echo "  GitHub (triggered by tag push):"
  echo "    5. CI: run tests, build release app bundle"
  echo "    6. Package Tabzilla.app → Tabzilla-$VERSION-macos.zip (with SHA256)"
  echo "    7. Create GitHub Release$(if [[ $FORCE -eq 1 ]]; then echo " (update existing if present)"; fi) with zip attached"
  echo "    8. Update Homebrew Cask in tabzilladev/homebrew-tap"
  echo ""
  echo "No changes made."
  exit 0
fi

# --- Execute ---

# Step 1-3: bump version and commit (skip if --force and version already matches)
if [[ $VERSION_CHANGED -eq 1 ]]; then
  "$REPO_ROOT/scripts/set-version.sh" "$VERSION"
  git -C "$REPO_ROOT" add "$CLI_SWIFT" "$PBXPROJ"
  git -C "$REPO_ROOT" commit -m "$VERSION"
fi

# Step: delete existing tags if --force
if [[ $FORCE -eq 1 ]]; then
  echo "Removing existing tag $TAG..."
  [[ $LOCAL_TAG_EXISTS -eq 1 ]] && git -C "$REPO_ROOT" tag -d "$TAG"
  [[ $REMOTE_TAG_EXISTS -eq 1 ]] && git -C "$REPO_ROOT" push origin ":refs/tags/$TAG"
fi

# Step: create and push tag
echo "Tagging $TAG..."
git -C "$REPO_ROOT" tag "$TAG"
git -C "$REPO_ROOT" push origin "$TAG"
echo "Pushed $TAG — CI release workflow triggered"
