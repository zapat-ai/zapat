#!/usr/bin/env bash
#
# Release script for Zapat
#
# Usage:
#   bin/release.sh patch    # 1.0.0 → 1.0.1
#   bin/release.sh minor    # 1.0.0 → 1.1.0
#   bin/release.sh major    # 1.0.0 → 2.0.0
#
# What it does:
#   1. Bumps version in package.json and .claude-plugin/plugin.json
#   2. Prompts you to update CHANGELOG.md
#   3. Commits the version bump
#   4. Creates a git tag (v1.2.3)
#   5. Creates a GitHub Release with notes from CHANGELOG.md
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# --- Helpers ---

die() { echo "Error: $*" >&2; exit 1; }

bold() { printf "\033[1m%s\033[0m" "$1"; }

# --- Validate ---

BUMP_TYPE="${1:-}"
if [[ ! "$BUMP_TYPE" =~ ^(patch|minor|major)$ ]]; then
    echo "Usage: bin/release.sh <patch|minor|major>"
    echo ""
    echo "  patch   Bug fixes, docs updates           (1.0.0 → 1.0.1)"
    echo "  minor   New features, backward-compatible  (1.0.0 → 1.1.0)"
    echo "  major   Breaking changes                   (1.0.0 → 2.0.0)"
    exit 1
fi

# Check we're on main
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    die "Releases must be made from the 'main' branch. You're on '$CURRENT_BRANCH'."
fi

# Check working directory is clean
if [[ -n "$(git status --porcelain)" ]]; then
    die "Working directory is not clean. Commit or stash your changes first."
fi

# Check gh is available
command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required. Install: brew install gh"
command -v jq >/dev/null 2>&1 || die "jq is required. Install: brew install jq"

# --- Get current version ---

CURRENT_VERSION=$(jq -r '.version' package.json)
if [[ -z "$CURRENT_VERSION" || "$CURRENT_VERSION" == "null" ]]; then
    die "Could not read version from package.json"
fi

# --- Calculate new version ---

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP_TYPE" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TAG="v${NEW_VERSION}"

echo ""
echo "  Current version:  $(bold "$CURRENT_VERSION")"
echo "  New version:      $(bold "$NEW_VERSION") ($BUMP_TYPE)"
echo "  Tag:              $(bold "$TAG")"
echo ""

# --- Confirm ---

read -rp "Proceed with release? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Bump version in files ---

echo ""
echo "Bumping version..."

# package.json
jq --arg v "$NEW_VERSION" '.version = $v' package.json > package.json.tmp && mv package.json.tmp package.json

# .claude-plugin/plugin.json
if [[ -f .claude-plugin/plugin.json ]]; then
    jq --arg v "$NEW_VERSION" '.version = $v' .claude-plugin/plugin.json > .claude-plugin/plugin.json.tmp && mv .claude-plugin/plugin.json.tmp .claude-plugin/plugin.json
fi

# dashboard/package.json (keep in sync)
if [[ -f dashboard/package.json ]]; then
    jq --arg v "$NEW_VERSION" '.version = $v' dashboard/package.json > dashboard/package.json.tmp && mv dashboard/package.json.tmp dashboard/package.json
fi

echo "  Updated package.json → $NEW_VERSION"
echo "  Updated .claude-plugin/plugin.json → $NEW_VERSION"
echo "  Updated dashboard/package.json → $NEW_VERSION"

# --- Check CHANGELOG ---

echo ""
if grep -q "\[$NEW_VERSION\]" CHANGELOG.md; then
    echo "  CHANGELOG.md already has a [$NEW_VERSION] entry."
else
    echo "  CHANGELOG.md does not have a [$NEW_VERSION] entry."
    echo ""
    echo "  Please update CHANGELOG.md before continuing."
    echo "  Add a section like:"
    echo ""
    echo "    ## [$NEW_VERSION] - $(date +%Y-%m-%d)"
    echo ""
    echo "    ### Added"
    echo "    - ..."
    echo ""
    echo "    ### Fixed"
    echo "    - ..."
    echo ""
    read -rp "  Open CHANGELOG.md in your editor? [Y/n] " OPEN_EDITOR
    if [[ ! "$OPEN_EDITOR" =~ ^[nN]$ ]]; then
        ${EDITOR:-vi} CHANGELOG.md
    fi

    # Re-check
    if ! grep -q "\[$NEW_VERSION\]" CHANGELOG.md; then
        die "CHANGELOG.md still missing [$NEW_VERSION] entry. Aborting."
    fi
fi

# --- Extract release notes from CHANGELOG ---

# Extract the section for this version (between ## [x.y.z] and the next ## [)
RELEASE_NOTES=$(awk "/^## \[$NEW_VERSION\]/{found=1; next} /^## \[/{if(found) exit} found{print}" CHANGELOG.md)

if [[ -z "$RELEASE_NOTES" ]]; then
    echo "  Warning: Could not extract release notes from CHANGELOG.md"
    RELEASE_NOTES="Release $TAG"
fi

# --- Commit ---

echo ""
echo "Committing version bump..."

git add package.json .claude-plugin/plugin.json CHANGELOG.md
[[ -f dashboard/package.json ]] && git add dashboard/package.json

git commit -m "$(cat <<EOF
chore: release $TAG

Bump version to $NEW_VERSION.
EOF
)"

# --- Tag ---

echo "Creating tag $TAG..."
git tag -a "$TAG" -m "Release $TAG"

# --- Push ---

echo ""
read -rp "Push to remote and create GitHub Release? [y/N] " PUSH_CONFIRM
if [[ "$PUSH_CONFIRM" =~ ^[yY]$ ]]; then
    echo "Pushing..."
    git push origin main
    git push origin "$TAG"

    echo "Creating GitHub Release..."
    gh release create "$TAG" \
        --title "$TAG" \
        --notes "$RELEASE_NOTES"

    echo ""
    echo "  Release $TAG published!"
    echo "  https://github.com/zapat-ai/zapat/releases/tag/$TAG"
else
    echo ""
    echo "  Tag $TAG created locally. When ready, run:"
    echo "    git push origin main"
    echo "    git push origin $TAG"
    echo "    gh release create $TAG --title \"$TAG\" --generate-notes"
fi

echo ""
echo "Done."
