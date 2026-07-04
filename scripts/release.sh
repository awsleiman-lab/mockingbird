#!/bin/zsh
set -euo pipefail

# Cuts and PUBLISHES a Mockingbird release:
#   1. Bumps CFBundleShortVersionString to the given version and increments CFBundleVersion.
#   2. Builds the notarized DMG (scripts/export_dmg.sh).
#   3. Sparkle-signs it (EdDSA key, keychain account "Mockingbird") and prepends the entry
#      to appcast.xml (tracked here as source of truth).
#   4. Pushes appcast.xml to the PUBLIC awsleiman171/mockingbird-releases repo and creates
#      the GitHub release v<version> there with the DMG attached.
#
# The source repo is private; releases live in the public repo — a feed or download URL
# pointing at a private repo 404s for everyone but the owner, which is how updates silently
# work for nobody. Same layout as Gibran's pipeline.
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

[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found — run 'swift build -c release' once first." >&2; exit 1; }

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
        # Re-releasing the same build (e.g. a fixed DMG): replace its item in place.
        src = re.sub(r"        <item>(?:(?!</item>).)*?" + re.escape(build_tag) + r".*?</item>\n",
                     item, src, count=1, flags=re.S)
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
# Appcast push first: it creates the initial commit on a brand-new repo, and GitHub refuses
# to create releases in a repo with no commits.
EXISTING_SHA="$(gh api "repos/$RELEASES_REPO/contents/appcast.xml" --jq .sha 2>/dev/null || true)"
gh api -X PUT "repos/$RELEASES_REPO/contents/appcast.xml" \
  -f message="Appcast: Mockingbird $VERSION" \
  -f content="$(base64 -i "$APPCAST")" \
  ${EXISTING_SHA:+-f sha="$EXISTING_SHA"} >/dev/null

if gh release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG_PATH" --clobber --repo "$RELEASES_REPO"
else
  gh release create "v$VERSION" "$DMG_PATH" --repo "$RELEASES_REPO" \
    --title "Mockingbird $VERSION" --notes "$NOTES"
fi

echo ""
echo "Published:"
echo "  DMG:  $DOWNLOAD_URL"
echo "  feed: https://raw.githubusercontent.com/$RELEASES_REPO/main/appcast.xml"
