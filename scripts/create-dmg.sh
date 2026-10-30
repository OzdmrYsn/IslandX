#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
    echo "Usage: $0 /path/to/islo.app /path/to/islo.dmg [version]" >&2
    exit 64
fi

app_path="${1:A}"
dmg_path="${2:A}"
version="${3:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")}"

if [[ ! -d "$app_path" ]]; then
    echo "Application not found: $app_path" >&2
    exit 66
fi

staging_dir=$(mktemp -d /tmp/IslandXDMG.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT

/usr/bin/ditto "$app_path" "$staging_dir/islo.app"
/bin/ln -s /Applications "$staging_dir/Applications"

/bin/mkdir -p "${dmg_path:h}"
if [[ -e "$dmg_path" ]]; then
    /bin/mv "$dmg_path" "$dmg_path.previous"
fi

/usr/sbin/diskutil image create from \
    --volumeName "islo. $version" \
    --format UDZO \
    "$staging_dir" \
    "$dmg_path"

/usr/bin/hdiutil verify "$dmg_path"
echo "DMG ready: $dmg_path"
