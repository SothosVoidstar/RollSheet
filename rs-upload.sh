#!/bin/bash
# ------------------------------------------------------------------
#  rs-upload.sh  ·  Upload a RollSheet release zip to CurseForge
#
#  Usage:
#    export CF_API_TOKEN="your-token"
#    ./rs-upload.sh PROJECT_ID RollSheet_v1.8.0.zip [GAME_VERSION] [release|beta|alpha]
#
#  GAME_VERSION defaults to 12.1.0, the release type to "release".
#  The display name and changelog are read from the zip itself:
#  the version from RollSheet.toc, and that version's section from
#  CHANGELOG.md.  Uses only tools that come with macOS.
# ------------------------------------------------------------------
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: ./rs-upload.sh PROJECT_ID ZIPFILE [GAME_VERSION] [release|beta|alpha]"
  exit 1
fi
PROJECT_ID="$1"
ZIP="$2"
GAME_VERSION="${3:-12.1.0}"
RELEASE_TYPE="${4:-release}"
if [ -z "${CF_API_TOKEN:-}" ]; then
  echo "Set your CurseForge API token first:  export CF_API_TOKEN=your-token"
  exit 1
fi

API="https://wow.curseforge.com/api"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$ZIP" ] || { echo "Zip not found: $ZIP"; exit 1; }

# 1. Addon version, straight from the TOC inside the zip
VERSION="$(unzip -p "$ZIP" RollSheet/RollSheet.toc | sed -n 's/^## Version: *//p' | tr -d '\r')"
[ -n "$VERSION" ] || { echo "Couldn't read ## Version from RollSheet/RollSheet.toc"; exit 1; }

# 2. This version's changelog section
unzip -p "$ZIP" RollSheet/CHANGELOG.md \
  | awk -v head="## v$VERSION" '$0 == head { found = 1; next } /^## v/ { if (found) exit } found' \
  > "$TMP/changelog.md"
[ -s "$TMP/changelog.md" ] || { echo "No '## v$VERSION' section in CHANGELOG.md"; exit 1; }

# 3. CurseForge's internal ID for the game version
curl -sSf -H "X-Api-Token: $CF_API_TOKEN" "$API/game/versions" -o "$TMP/versions.json" \
  || { echo "Couldn't fetch game versions. Check your API token."; exit 1; }

# 4. Build the metadata JSON (macOS's built-in JavaScript does the escaping)
osascript -l JavaScript - "$TMP" "$GAME_VERSION" "$VERSION" "$RELEASE_TYPE" << 'JS'
ObjC.import('Foundation');
function read(p) { return $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null).js; }
function run(argv) {
  var dir = argv[0], gameVersion = argv[1], version = argv[2], releaseType = argv[3];
  var ids = JSON.parse(read(dir + '/versions.json'))
              .filter(function (v) { return v.name === gameVersion; })
              .map(function (v) { return v.id; });
  if (!ids.length) throw new Error('Game version "' + gameVersion + '" not found on CurseForge');
  var meta = {
    changelog: read(dir + '/changelog.md'),
    changelogType: 'markdown',
    displayName: 'RollSheet ' + version,
    gameVersions: ids,
    releaseType: releaseType
  };
  $.NSString.alloc.initWithUTF8String(JSON.stringify(meta))
    .writeToFileAtomicallyEncodingError(dir + '/metadata.json', true, $.NSUTF8StringEncoding, null);
  return 'Game version ' + gameVersion + ' -> CurseForge id ' + ids.join(', ');
}
JS

# 5. Confirm, then upload
echo
echo "  Project:  $PROJECT_ID"
echo "  File:     $ZIP"
echo "  Name:     RollSheet $VERSION ($RELEASE_TYPE, WoW $GAME_VERSION)"
echo "  Changelog: $(wc -l < "$TMP/changelog.md" | tr -d ' ') lines from CHANGELOG.md"
echo
read -r -p "Upload to CurseForge? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

curl -sS -H "X-Api-Token: $CF_API_TOKEN" \
     -F "metadata=<$TMP/metadata.json" \
     -F "file=@$ZIP" \
     "$API/projects/$PROJECT_ID/upload-file"
echo
