#!/bin/zsh
# Re-signs islo.app (and the Sparkle parts inside it) with a stable identity.
#
# Ad-hoc signatures change with every build, so macOS forgets permissions such
# as Accessibility after each update. Signing every release with the same
# certificate keeps the app's designated requirement stable, so permissions
# granted once survive later updates.
#
# Usage: scripts/sign-app.sh path/to/islo.app
# Identity: $ISLO_SIGNING_IDENTITY (default "islo Code Signing").
set -euo pipefail

app_path="${1:?usage: sign-app.sh path/to/islo.app}"
project_root="${0:A:h:h}"
identity="${ISLO_SIGNING_IDENTITY:-islo Code Signing}"
entitlements="$project_root/islo/islo.entitlements"

if [[ "$identity" != "-" ]] && ! /usr/bin/security find-identity -p codesigning | grep -Fq "\"$identity\""; then
    echo "Uyarı: \"$identity\" imzalama kimliği bulunamadı; ad-hoc imza kullanılıyor." >&2
    echo "Bu derlemeyle izinler (Erişilebilirlik vb.) güncellemede sıfırlanır." >&2
    identity="-"
fi

sign() {
    /usr/bin/codesign --force --timestamp=none --options runtime --sign "$identity" "$@"
}

sparkle="$app_path/Contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
    # Inside-out order, as described in Sparkle's documentation.
    sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    sign "$sparkle/Versions/B/Autoupdate"
    sign "$sparkle/Versions/B/Updater.app"
    sign "$sparkle"
fi

sign --entitlements "$entitlements" "$app_path"

/usr/bin/codesign --verify --deep --strict "$app_path"
echo "İmzalandı ($identity): $app_path"
/usr/bin/codesign --display --requirements - "$app_path" 2>/dev/null | sed -n 's/^designated => /  Gereksinim: /p'
