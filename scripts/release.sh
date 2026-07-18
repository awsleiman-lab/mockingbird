#!/bin/zsh
set -euo pipefail

# Cuts and PUBLISHES a Mockingbird release:
#   1. Bumps CFBundleShortVersionString to the given version and increments CFBundleVersion.
#   2. Builds the notarized DMG (scripts/export_dmg.sh).
#   3. Sparkle-signs it (EdDSA key, keychain account "Mockingbird") and prepends the entry
#      to appcast.xml (tracked here as source of truth).
#   4. Creates the GitHub release v<version> in the PUBLIC
#      awsleiman171/mockingbird-releases repo with the DMG attached.
#   5. Atomically updates appcast.xml and .website/app.md in that repo so
#      www.awsleiman.com and the Sparkle feed always publish the same version.
#   6. Commits the release changes here (Info.plist, appcast), tags v<version>, pushes
#      branch + tag to origin, and creates a GitHub release on this repo from the tag
#      (notes + DMG link, no binary) so releases are trackable next to the code.
#
# The source repo and updater repo are public. Keeping the binary and Sparkle feed in the
# dedicated updater repo gives the website and installed apps stable download URLs.
#
# Prerequisites: `gh auth login` once (account awsleiman171).
# Usage: scripts/release.sh 1.0.2 ["release notes"]

VERSION="${1:?usage: release.sh <marketing version, e.g. 1.0.2> [notes]}"
NOTES="${2:-Improvements and fixes.}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/AppBundle/Contents/Info.plist"
RELEASES="$ROOT/dist/releases"
APPCAST="$ROOT/appcast.xml"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
RELEASES_REPO="${MOCKINGBIRD_RELEASES_REPO:-awsleiman171/mockingbird-releases}"
DOWNLOAD_URL="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/Mockingbird-$VERSION.dmg"
SOURCE_REPO="${MOCKINGBIRD_SOURCE_REPO:-awsleiman-lab/mockingbird}"
WEBSITE_MD=".website/app.md"

[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found — run 'swift build -c release' once first." >&2; exit 1; }
gh repo view "$RELEASES_REPO" >/dev/null 2>&1 || {
  echo "Release repository $RELEASES_REPO does not exist or is inaccessible." >&2
  exit 1
}
gh api "repos/$RELEASES_REPO/contents/$WEBSITE_MD" >/dev/null 2>&1 || {
  echo "$WEBSITE_MD not found in $RELEASES_REPO; restore it before releasing." >&2
  exit 1
}
if gh release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1 \
   || gh api "repos/$RELEASES_REPO/git/ref/tags/v$VERSION" >/dev/null 2>&1 \
   || gh release view "v$VERSION" --repo "$SOURCE_REPO" >/dev/null 2>&1 \
   || git -C "$ROOT" show-ref --verify --quiet "refs/tags/v$VERSION" \
   || git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
  echo "Version v$VERSION already exists. Choose a new version; published releases are immutable." >&2
  exit 1
fi

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NEW_BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "Releasing Mockingbird $VERSION (build $NEW_BUILD)"

"$ROOT/scripts/export_dmg.sh"

mkdir -p "$RELEASES"
DMG_PATH="$RELEASES/Mockingbird-$VERSION.dmg"
cp "$ROOT/dist/Mockingbird.dmg" "$DMG_PATH"

echo "==> Sparkle-signing"
SIG_LINE="$("$SIGN_UPDATE" --account Mockingbird "$DMG_PATH")"
ED_SIGNATURE="$(sed 's/.*edSignature="\([^"]*\)".*/\1/' <<<"$SIG_LINE")"
LENGTH="$(sed 's/.*length="\([^"]*\)".*/\1/' <<<"$SIG_LINE")"
[[ -n "$ED_SIGNATURE" && -n "$LENGTH" ]] || { echo "Could not parse sign_update output: $SIG_LINE" >&2; exit 1; }

echo "==> Updating appcast.xml"
PUB_DATE="$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")"
export VERSION NEW_BUILD DOWNLOAD_URL ED_SIGNATURE LENGTH PUB_DATE NOTES APPCAST
python3 - <<'EOF'
import html, os, re

appcast = os.environ["APPCAST"]
item = f"""        <item>
            <title>{os.environ["VERSION"]}</title>
            <pubDate>{os.environ["PUB_DATE"]}</pubDate>
            <sparkle:version>{os.environ["NEW_BUILD"]}</sparkle:version>
            <sparkle:shortVersionString>{os.environ["VERSION"]}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <description><![CDATA[{os.environ["NOTES"]}]]></description>
            <enclosure url="{html.escape(os.environ["DOWNLOAD_URL"])}" length="{os.environ["LENGTH"]}" type="application/octet-stream" sparkle:edSignature="{os.environ["ED_SIGNATURE"]}"/>
        </item>
"""
if os.path.exists(appcast):
    src = open(appcast).read()
    build_tag = f"<sparkle:version>{os.environ['NEW_BUILD']}</sparkle:version>"
    if build_tag in src:
        raise SystemExit(f"build {os.environ['NEW_BUILD']} already exists in the appcast")
    else:
        src = src.replace("<title>Mockingbird</title>\n", "<title>Mockingbird</title>\n" + item, 1)
else:
    src = f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Mockingbird</title>
{item}    </channel>
</rss>
"""
open(appcast, "w").write(src)
print("appcast updated")
EOF

echo "==> Publishing to $RELEASES_REPO"
# Release first, appcast second: the moment the appcast goes live its enclosure URL must
# already resolve, otherwise apps that check during the gap show users a failed update.
RELEASE_FLAGS=()
if [[ "$VERSION" == *-* ]]; then
  RELEASE_FLAGS+=(--prerelease --latest=false)
fi
gh release create "v$VERSION" "$DMG_PATH" --repo "$RELEASES_REPO" \
  --title "Mockingbird $VERSION" --notes "$NOTES" "${RELEASE_FLAGS[@]}"

echo "==> Publishing appcast.xml + $WEBSITE_MD atomically"
BRANCH="$(gh api "repos/$RELEASES_REPO" --jq .default_branch)"
HEAD_SHA="$(gh api "repos/$RELEASES_REPO/git/ref/heads/$BRANCH" --jq .object.sha)"
APP_MD_FILE="$(mktemp)"
trap 'rm -f "$APP_MD_FILE"' EXIT
gh api "repos/$RELEASES_REPO/contents/$WEBSITE_MD?ref=$BRANCH" \
  -H "Accept: application/vnd.github.raw" > "$APP_MD_FILE"
export APP_MD_FILE
python3 - <<'EOF'
import os, re, sys

path = os.environ["APP_MD_FILE"]
src = open(path).read()

new, n_ver = re.subn(r"^version:.*$", f"version: {os.environ['VERSION']}", src, count=1, flags=re.M)
new, n_dl = re.subn(r"^download:.*$", f"download: {os.environ['DOWNLOAD_URL']}", new, count=1, flags=re.M)
if not (n_ver and n_dl):
    sys.exit(f"could not find 'version:'/'download:' frontmatter in {path}")
open(path, "w").write(new)
EOF

BASE_TREE="$(gh api "repos/$RELEASES_REPO/git/commits/$HEAD_SHA" --jq .tree.sha)"
APPCAST_BLOB="$(gh api -X POST "repos/$RELEASES_REPO/git/blobs" \
  -f encoding=base64 -f content="$(base64 -i "$APPCAST")" --jq .sha)"
APP_MD_BLOB="$(gh api -X POST "repos/$RELEASES_REPO/git/blobs" \
  -f encoding=base64 -f content="$(base64 -i "$APP_MD_FILE")" --jq .sha)"
TREE_SHA="$(python3 -c 'import json, sys
base, appcast, app_md = sys.argv[1:4]
print(json.dumps({"base_tree": base, "tree": [
    {"path": "appcast.xml", "mode": "100644", "type": "blob", "sha": appcast},
    {"path": ".website/app.md", "mode": "100644", "type": "blob", "sha": app_md},
]}))' "$BASE_TREE" "$APPCAST_BLOB" "$APP_MD_BLOB" \
  | gh api -X POST "repos/$RELEASES_REPO/git/trees" --input - --jq .sha)"
COMMIT_SHA="$(gh api -X POST "repos/$RELEASES_REPO/git/commits" \
  -f message="Release Mockingbird $VERSION: appcast + website page" \
  -f tree="$TREE_SHA" -f "parents[]=$HEAD_SHA" --jq .sha)"
gh api -X PATCH "repos/$RELEASES_REPO/git/refs/heads/$BRANCH" -f sha="$COMMIT_SHA" >/dev/null

echo "==> Tagging source repo v$VERSION"
git -C "$ROOT" add appcast.xml AppBundle/Contents/Info.plist
git -C "$ROOT" diff --cached --quiet || git -C "$ROOT" commit -m "Release $VERSION (build $NEW_BUILD)"
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "    note: working tree has other uncommitted changes — the tag will not include them"
fi
git -C "$ROOT" tag -a "v$VERSION" -m "Mockingbird $VERSION (build $NEW_BUILD)

$NOTES"
git -C "$ROOT" push origin HEAD
git -C "$ROOT" push origin "refs/tags/v$VERSION"

# Mirror the release on the source repo (no binary — the DMG lives on the public
# releases repo) so the tag shows up under Releases with its notes.
SOURCE_NOTES="$NOTES

Download: $DOWNLOAD_URL"
gh release create "v$VERSION" --repo "$SOURCE_REPO" --verify-tag \
  --title "Mockingbird $VERSION" --notes "$SOURCE_NOTES" "${RELEASE_FLAGS[@]}" >/dev/null

echo ""
echo "Published:"
echo "  DMG:  $DOWNLOAD_URL"
echo "  feed: https://raw.githubusercontent.com/$RELEASES_REPO/main/appcast.xml"
echo "  site: $WEBSITE_MD @ $RELEASES_REPO (version $VERSION)"
echo "  tag:  v$VERSION @ $(git -C "$ROOT" remote get-url origin)"
