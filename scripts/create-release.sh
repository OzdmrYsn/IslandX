#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

repository="${ISLO_GITHUB_REPOSITORY:-OzdmrYsn/islo}"
info_plist="$project_root/islo/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
package_cache="$project_root/.sparkle-packages"
derived_data=$(mktemp -d /tmp/isloRelease.XXXXXX)
appcast_input=$(mktemp -d /tmp/IsloAppcast.XXXXXX)
trap 'rm -rf "$derived_data" "$appcast_input"' EXIT
archive_name="islo-$version.zip"
archive_path="$project_root/dist/$archive_name"
dmg_path="$project_root/dist/islo.dmg"

mkdir -p "$project_root/dist"

xcodebuild \
    -resolvePackageDependencies \
    -project islo.xcodeproj \
    -scheme islo \
    -clonedSourcePackagesDirPath "$package_cache"

xcodebuild \
    -project islo.xcodeproj \
    -scheme islo \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$package_cache" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    build

release_app="$derived_data/Build/Products/Release/islo.app"
/usr/bin/codesign --verify --deep --strict "$release_app"

if [[ -e "$archive_path" ]]; then
    backup_path="$project_root/dist/$archive_name.previous"
    mv "$archive_path" "$backup_path"
fi

/usr/bin/ditto \
    -c -k --sequesterRsrc --keepParent \
    "$release_app" \
    "$archive_path"

"$project_root/scripts/create-dmg.sh" \
    "$release_app" \
    "$dmg_path" \
    "$version"

generate_appcast="$package_cache/artifacts/sparkle/Sparkle/bin/generate_appcast"
download_prefix="https://github.com/$repository/releases/download/v$version/"
cp "$archive_path" "$appcast_input/$archive_name"

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    print -rn -- "$SPARKLE_PRIVATE_KEY" | "$generate_appcast" \
        --ed-key-file - \
        --download-url-prefix "$download_prefix" \
        --link "https://github.com/$repository" \
        --maximum-versions 3 \
        -o "$project_root/appcast.xml" \
        "$appcast_input"
else
    "$generate_appcast" \
        --download-url-prefix "$download_prefix" \
        --link "https://github.com/$repository" \
        --maximum-versions 3 \
        -o "$project_root/appcast.xml" \
        "$appcast_input"
fi

echo "islo. $version ($build) hazır:"
echo "  $archive_path"
echo "  $dmg_path"
echo "  $project_root/appcast.xml"
echo "ZIP ve DMG'yi GitHub Release v$version'a yükleyin; ardından appcast.xml'i yayınlayın."
