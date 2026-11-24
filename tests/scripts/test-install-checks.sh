#!/bin/sh
# Tests of scripts/install-checks.sh, the four decisions scripts/install-driver.sh takes from it:
# whether the installed app has the configured bundle ID (installed_id_line), which listed driver
# versions have no kept app (missing_kept_apps), the line about the running driver (running_line),
# and whether every personality of the new build has the configured RMNetIPv6OnlyPreferred
# (ipv6_only_preferred_line, on copies of driver/Info.plist edited with plutil). The listings under
# fixtures/ are in `systemextensionsctl list` format. Run by `make script-test`; it installs nothing
# and reads nothing of the system's.
set -u

cd "$(dirname "$0")/../.." || exit 1
FIX=tests/scripts/fixtures
ID=io.rmnetdriver.RMNet.driver

pass=0
fail=0
# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  expected: "%s"\n  actual:   "%s"\n' "$1" "$2" "$3" >&2
  fi
}

[ -f scripts/install-checks.sh ] || {
  echo "test-install-checks: FAIL: scripts/install-checks.sh does not exist" >&2
  exit 1
}
. ./scripts/install-checks.sh

KEEP=$(mktemp -d "${TMPDIR:-/tmp}/install-checks.XXXXXX") || exit 1
EMPTY_KEEP=$(mktemp -d "${TMPDIR:-/tmp}/install-checks.XXXXXX") || exit 1
PL=$(mktemp -d "${TMPDIR:-/tmp}/install-checks.XXXXXX") || exit 1
trap 'rm -rf "$KEEP" "$EMPTY_KEEP" "$PL"' EXIT
mkdir "$KEEP/RMNet-317.18.40.app"

# --- installed_id_line <installed app's bundle ID> <configured bundle ID> ---

# The line and the return status: "<line>|<status>".
id_line() {
  il=$(installed_id_line "$1" "$2")
  echo "$il|$?"
}
REFUSAL_END='as configured (config.local or the environment): if systemextensionsctl list still shows its driver, remove that first with this app (docs/reference.md, Removing the driver); then delete the app and run again; nothing was changed'
check "no installed app" "|0" "$(id_line '' io.rmnetdriver.RMNet)"
check "the installed app has the configured bundle ID" "|0" "$(id_line io.rmnetdriver.RMNet io.rmnetdriver.RMNet)"
check "the installed app has another bundle ID: refused, naming both" \
  "the installed app's bundle ID is io.rmnetdriver.RMNet, not io.rmnetdriver.RMnet $REFUSAL_END|1" \
  "$(id_line io.rmnetdriver.RMNet io.rmnetdriver.RMnet)"
check "the installed app's bundle ID could not be read: refused" \
  "the installed app's bundle ID is (none readable), not com.example.RMNet $REFUSAL_END|1" \
  "$(id_line '(none readable)' com.example.RMNet)"

# --- missing_kept_apps ---

check "an activated enabled entry with a kept app is not printed" \
  "" "$(missing_kept_apps "$FIX/listing-one-enabled.txt" "$KEEP" "$ID")"
check "an activated enabled entry without a kept app is printed" \
  "317.18.40" "$(missing_kept_apps "$FIX/listing-one-enabled.txt" "$EMPTY_KEEP" "$ID")"
check "an activated waiting for user entry without a kept app is printed" \
  "317.19.2" "$(missing_kept_apps "$FIX/listing-waiting-for-user.txt" "$KEEP" "$ID")"
check "a terminated waiting to uninstall on reboot entry without a kept app is not printed" \
  "" "$(missing_kept_apps "$FIX/listing-uninstalling.txt" "$KEEP" "$ID")"
check "with no kept app at all, only the uninstalling entry is left out" \
  "317.18.40" "$(missing_kept_apps "$FIX/listing-uninstalling.txt" "$EMPTY_KEEP" "$ID")"
check "several entries: every one without a kept app, in listing order, but the uninstalling one and another driver's" \
  "$(printf '%s\n' 317.16.8 317.19.2)" "$(missing_kept_apps "$FIX/listing-several.txt" "$KEEP" "$ID")"
check "several entries, none kept" \
  "$(printf '%s\n' 317.18.40 317.16.8 317.19.2)" "$(missing_kept_apps "$FIX/listing-several.txt" "$EMPTY_KEEP" "$ID")"
check "a listing without the driver prints nothing" \
  "" "$(missing_kept_apps "$FIX/listing-none.txt" "$EMPTY_KEEP" "$ID")"
missing_kept_apps "$FIX/listing-several.txt" "$KEEP" "$ID" >/dev/null
check "missing_kept_apps succeeds when it prints versions" "0" "$?"
missing_kept_apps "$FIX/listing-none.txt" "$KEEP" "$ID" >/dev/null
check "missing_kept_apps succeeds when it prints nothing" "0" "$?"
missing_kept_apps "$FIX/no-such-listing.txt" "$KEEP" "$ID" >/dev/null 2>&1
check "missing_kept_apps fails when the listing cannot be read" "1" "$?"

# --- running_line <new-cdhash> <running-cdhash> <version> ---

check "the new build's CDHash equals the running one's" \
  "version 317.18.41 is the running driver" "$(running_line 1f2e3d 1f2e3d 317.18.41)"
check "the running CDHash differs from the new build's" \
  "$(printf '%s\n' 'an older build is still running; version 317.18.41 loads when the modem re-enumerates' \
    '(unplug it, or send AT+CFUN=1,1)')" "$(running_line 1f2e3d 4c5b6a 317.18.41)"
check "no running driver" \
  "no RMNetDriver attached (modem not attached in QMI mode?)" "$(running_line 1f2e3d '' 317.18.41)"
check "the new build's CDHash cannot be read" \
  "cannot read the CDHash of version 317.18.41; whether it is the running driver is not known" \
  "$(running_line '' 4c5b6a 317.18.41)"
check "neither CDHash: no running driver is the answer" \
  "no RMNetDriver attached (modem not attached in QMI mode?)" "$(running_line '' '' 317.18.41)"

# --- ipv6_only_preferred_line <the built driver's Info.plist> <configured value> ---

# The line and the return status, "<line>|<status>", with the plists' directory left out of the line.
v6_line() {
  vl=$(ipv6_only_preferred_line "$PL/$1" "$2")
  printf '%s|%s\n' "$vl" "$?" | sed "s#$PL/##g"
}
# plist <name> <copy of>: a copy, edited after with plutil.
plist() { cp "$PL/$2" "$PL/$1"; }

cp driver/Info.plist "$PL/off.plist"
awk '/<key>RMNetIPv6OnlyPreferred<\/key>/ { print; getline; sub(/<integer>0</, "<integer>1<") } { print }' \
  "$PL/off.plist" >"$PL/on.plist"
check "driver/Info.plist, configured 0: every personality agrees" "|0" "$(v6_line off.plist 0)"
check "a build with each personality's 0 turned to 1, configured 1: every personality agrees" "|0" "$(v6_line on.plist 1)"
check "driver/Info.plist, configured 1: refused, every RMNetDriver personality named" \
  "RMNetIPv6OnlyPreferred is not 1 (as configured) in every personality of off.plist: RMNetDriver 0, RMNetDriver_0121 0, RMNetDriver_0122 0, RMNetDriver_0125 0, RMNetDriver_013d 0, RMNetDriver_0191 0, RMNetDriver_0195 0, RMNetDriver_0296 0, RMNetDriver_0306 0, RMNetDriver_030b 0, RMNetDriver_030e 0, RMNetDriver_0512 0, RMNetDriver_0620 0, RMNetDriver_0800 0|1" \
  "$(v6_line off.plist 1)"
plist one-off.plist on.plist
plutil -replace IOKitPersonalities.RMNetDriver_0800.RMNetIPv6OnlyPreferred -integer 0 "$PL/one-off.plist"
check "one personality other than the main one left at 0: refused, naming it" \
  "RMNetIPv6OnlyPreferred is not 1 (as configured) in every personality of one-off.plist: RMNetDriver_0800 0|1" \
  "$(v6_line one-off.plist 1)"
plist main-missing.plist on.plist
plutil -remove IOKitPersonalities.RMNetDriver.RMNetIPv6OnlyPreferred "$PL/main-missing.plist"
check "the main personality without the key: refused" \
  "RMNetIPv6OnlyPreferred is not 1 (as configured) in every personality of main-missing.plist: RMNetDriver none|1" \
  "$(v6_line main-missing.plist 1)"
plist several.plist one-off.plist
plutil -remove IOKitPersonalities.RMNetDriver_0121.RMNetIPv6OnlyPreferred "$PL/several.plist"
plutil -replace IOKitPersonalities.RMNetDriver_0122.RMNetIPv6OnlyPreferred -string 1 "$PL/several.plist"
check "a missing key, a string and a 0: each named, in byte order" \
  "RMNetIPv6OnlyPreferred is not 1 (as configured) in every personality of several.plist: RMNetDriver_0121 none, RMNetDriver_0122 not an integer, RMNetDriver_0800 0|1" \
  "$(v6_line several.plist 1)"
plist serial-other.plist on.plist
plutil -insert IOKitPersonalities.RMNetSerialDIAG.RMNetIPv6OnlyPreferred -integer 0 "$PL/serial-other.plist"
check "another personality with the key at another value: refused" \
  "RMNetIPv6OnlyPreferred is not 1 (as configured) in every personality of serial-other.plist: RMNetSerialDIAG 0|1" \
  "$(v6_line serial-other.plist 1)"
plist serial-same.plist on.plist
plutil -insert IOKitPersonalities.RMNetSerialDIAG.RMNetIPv6OnlyPreferred -integer 1 "$PL/serial-same.plist"
check "another personality with the key at the configured value: agrees" "|0" "$(v6_line serial-same.plist 1)"
check "a serial personality without the key is not asked for it" "|0" "$(v6_line on.plist 1)"
plist no-driver.plist off.plist
for name in $(plutil -extract IOKitPersonalities raw -expect dictionary -o - "$PL/off.plist" | grep '^RMNetDriver'); do
  plutil -remove "IOKitPersonalities.$name" "$PL/no-driver.plist"
done
check "no RMNetDriver personality: refused" "no-driver.plist has no RMNetDriver personality|1" "$(v6_line no-driver.plist 0)"
check "no such plist: refused" "missing.plist has no IOKitPersonalities dictionary that can be read|1" \
  "$(v6_line missing.plist 0)"

echo "test-install-checks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
