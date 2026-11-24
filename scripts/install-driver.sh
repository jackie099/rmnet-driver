#!/bin/sh
# Signed build of the RMNet host app and driver, installed to /Applications/RMNet.app and activated.
# Every run gets a new, increasing CFBundleVersion, so activation replaces a running driver. A dext's
# CFBundleVersion must be a valid kext version (major up to 4 digits, minor and revision up to 2),
# so it is <days since 2026-01-01>.<hour>.<minute>, in UTC. Two installs in the same minute get the
# same version; the script refuses the second rather than install a build the system would not load.
# The first activation needs the owner's approval in System Settings. The signing team and the
# bundle IDs come from config.local or the environment (scripts/config.sh, config.example); the
# script refuses, before anything is built, unless both are set. RMNET_IPV6_ONLY_PREFERRED=1 there
# builds the driver with RMNetIPv6OnlyPreferred 1 (gen.rb; config.example says when to).
#
# A driver can only be deactivated by an app that embeds that exact driver version, so a copy of
# every app that asks for activation is kept in build/installed/RMNet-<version>.app
# (docs/reference.md, "Removing the driver"): the new app is kept before it asks, and the app it
# replaces is kept before it is removed if the system lists any entry with its version. Before that,
# the script stops, changing nothing, if any other listed version (an uninstalling entry aside) has
# no kept app.
# Nothing here deactivates.
set -eu

cd "$(dirname "$0")/.." || exit 1
. ./scripts/install-checks.sh # installed_id_line, missing_kept_apps, running_line, ipv6_only_preferred_line
. ./scripts/config.sh         # rmnet_config_require: TEAM_ID, BUNDLE_ID, DRIVER_ID, IPV6_ONLY_PREFERRED
rmnet_config_require || exit 2

BUILD="$PWD/build/xcode-signed"
NEW="$BUILD/Release/RMNet.app"
APP=/Applications/RMNet.app
KEEP="$PWD/build/installed"

# The app to be replaced must have the configured bundle ID, before anything is built or changed:
# every check below goes by $DRIVER_ID, so an app under another ID (config.local changed, or a typo)
# would be removed without a kept copy.
installed_id=
if [ -e "$APP" ]; then
  installed_id=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null) &&
    [ -n "$installed_id" ] || installed_id='(none readable)'
fi
if ! id_line=$(installed_id_line "$installed_id" "$BUNDLE_ID"); then
  echo "install-driver: $APP: $id_line" >&2
  exit 2
fi

now=$(date -u +%s)
epoch=$(date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-01-01 00:00:00' +%s)
secs=$((now - epoch))
VERSION="$((secs / 86400)).$((secs % 86400 / 3600)).$((secs % 3600 / 60))"

stage=start
step() {
  stage=$1
  echo "==> $1"
}
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "install-driver: failed during: $stage" >&2' EXIT

# Reads the system's list of extensions into $listing. A failed listing stops the script: read as
# an empty list, it would look like "nothing installed" and let the app be replaced without a copy.
# $1 says what has been changed by then, for the message.
read_listing() {
  listing=$(systemextensionsctl list) || {
    echo "install-driver: systemextensionsctl list failed; stopping $1" >&2
    exit 1
  }
}

# The versions of every entry in $listing for the driver, whatever its state, one per line.
# With "activated enabled" as $1, only that entry's version. (Which versions lack a kept app is
# decided by missing_kept_apps, in scripts/install-checks.sh.)
listed_versions() {
  printf '%s\n' "$listing" | grep "	$DRIVER_ID (" | grep -- "${1:-}" |
    sed -n 's/.*(\([^/]*\)\/\([0-9.]*\)).*/\2/p'
}

active_version() {
  listed_versions 'activated enabled' | head -1
}

# The version of the driver embedded in the app at $1, or nothing.
driver_version() {
  /usr/bin/defaults read "$1/Contents/Library/SystemExtensions/$DRIVER_ID.dext/Info" CFBundleVersion 2>/dev/null || true
}

# Keeps a copy of the app at $1 as build/installed/RMNet-<driver version>.app. The copy is made
# under a temporary name and renamed, so a kept app is never a partial one.
keep_app() {
  v=$(driver_version "$1")
  [ -n "$v" ] || { echo "install-driver: no driver version in $1" >&2; return 1; }
  [ -d "$KEEP/RMNet-$v.app" ] && return 0
  mkdir -p "$KEEP"
  rm -rf "$KEEP/.partial.app"
  ditto "$1" "$KEEP/.partial.app"
  mv "$KEEP/.partial.app" "$KEEP/RMNet-$v.app"
  echo "kept $KEEP/RMNet-$v.app"
}

installed=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || true)
if [ "$installed" = "$VERSION" ]; then
  echo "install-driver: version $VERSION is already installed; wait a minute and run again" >&2
  exit 1
fi

step "generate RMNet.xcodeproj for team $TEAM_ID, bundle ID $BUNDLE_ID, IPv6-only preferred $IPV6_ONLY_PREFERRED"
/usr/bin/ruby gen.rb --team "$TEAM_ID" --bundle-id "$BUNDLE_ID" --ipv6-only-preferred "$IPV6_ONLY_PREFERRED"

step "signed build, version $VERSION"
rm -rf "$NEW"
xcodebuild -project RMNet.xcodeproj -target RMNet -configuration Release -parallelizeTargets \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  SYMROOT="$BUILD" OBJROOT="$BUILD/obj" CURRENT_PROJECT_VERSION="$VERSION" build

step "check the new build"
built=$(/usr/bin/defaults read "$NEW/Contents/Info" CFBundleVersion 2>/dev/null || true)
[ "$built" = "$VERSION" ] || { echo "install-driver: $NEW missing or not version $VERSION" >&2; exit 1; }
# Every RMNetDriver personality of the built driver has the configured RMNetIPv6OnlyPreferred, and
# no personality another value.
if ! v6only_line=$(ipv6_only_preferred_line "$NEW/Contents/Library/SystemExtensions/$DRIVER_ID.dext/Info.plist" \
  "$IPV6_ONLY_PREFERRED"); then
  echo "install-driver: the new build: $v6only_line" >&2
  exit 1
fi

step "keep the app being replaced"
read_listing "before anything is changed"
old=$(driver_version "$APP")
# Every listed version but an uninstalling entry's needs a kept app, or it could not be deactivated:
# the active one, one waiting for approval, a switched-off one. The app being replaced is kept just
# below, so its own version may still be missing here; any other missing one stops the script
# before anything is changed.
missing=$(printf '%s\n' "$listing" | missing_kept_apps /dev/stdin "$KEEP" "$DRIVER_ID") || {
  echo "install-driver: the listing could not be checked for kept apps; nothing was changed" >&2
  exit 1
}
others=
for ver in $missing; do
  [ "$ver" = "$old" ] || others="$others $ver"
done
if [ -n "$others" ]; then
  echo "install-driver: listed driver version(s)$others have no kept app in $KEEP ($APP is ${installed:-missing})" >&2
  echo "install-driver: without one they cannot be deactivated; see docs/reference.md, Removing the driver; nothing was changed" >&2
  exit 1
fi
if [ -n "$old" ] && listed_versions | grep -qxF "$old"; then
  keep_app "$APP"
fi
if [ -z "$(listed_versions)" ]; then
  echo "no $DRIVER_ID listed"
else
  echo "every listed $DRIVER_ID version but an uninstalling one has a kept app in $KEEP"
fi

step "copy to $APP"
rm -rf "$APP"
ditto "$NEW" "$APP"
keep_app "$APP"

step "activate"
"$APP/Contents/MacOS/RMNet" activate
read_listing "after $APP was replaced and activated; the active version is not checked"
active=$(active_version)
[ "$active" = "$VERSION" ] || { echo "install-driver: active driver is ${active:-none}, not $VERSION" >&2; exit 1; }

# A running RMNetDriver is not stopped by a replacement (its services refuse to terminate), so the
# new build only loads when the modem re-enumerates. Say so rather than leave the old one running.
step "check the running driver"
new=$(codesign -dvvv "$APP/Contents/Library/SystemExtensions/$DRIVER_ID.dext" 2>&1 | sed -n 's/^CDHash=//p')
running=$(ioreg -r -n RMNetDriver -d 1 -w0 | sed -n 's/.*"IOUserServerCDHash" = "\([0-9a-f]*\)".*/\1/p' | head -1)
running_line "$new" "$running" "$VERSION"

step "done"
