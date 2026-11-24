# The four checks of scripts/install-driver.sh that can be tested without an install, sourced by it
# and by tests/scripts/test-install-checks.sh (`make script-test`). Functions only: sourcing this file
# runs nothing. Their variables start with ic_, so they do not change the caller's.

# installed_id_line <installed app's bundle ID> <configured bundle ID>
# Succeeds, printing nothing, when there is no installed app (the first argument is empty) or it has
# the configured bundle ID. Otherwise prints the refusal line, naming both, and fails: the kept-app
# checks below and the driver version read from the app go by the configured driver ID, so an app
# (and its listed driver) under another ID would be replaced without a kept copy, and a second driver
# with the same personalities activated beside it. The caller passes "(none readable)" for an app
# whose bundle ID cannot be read, which is refused like any other.
installed_id_line() {
  if [ -z "$1" ] || [ "$1" = "$2" ]; then
    return 0
  fi
  echo "the installed app's bundle ID is $1, not $2 as configured (config.local or the environment):" \
    "if systemextensionsctl list still shows its driver, remove that first with this app" \
    "(docs/reference.md, Removing the driver); then delete the app and run again; nothing was changed"
  return 1
}

# missing_kept_apps <listing-text-file> <keep-dir> <driver-id>
# Prints, one per line in listing order, every version listed for <driver-id> in the file (the output
# of `systemextensionsctl list`) whose state does not contain "uninstall" and for which
# <keep-dir>/RMNet-<version>.app does not exist: each of them could not be deactivated without that
# app (docs/reference.md, "Removing the driver"). An entry's version is the one after the "/" in
# "<driver-id> (<short version>/<version>)". Fails if the file cannot be read.
missing_kept_apps() {
  ic_versions=$(awk -F '\t' -v id="$3" '
    index($4, id " (") == 1 && $NF !~ /uninstall/ && match($4, /\/[0-9.]+\)$/) {
      v = substr($4, RSTART + 1, RLENGTH - 2)
      if (!(v in seen)) { seen[v] = 1; print v }
    }' "$1") || return 1
  for ic_v in $ic_versions; do
    [ -d "$2/RMNet-$ic_v.app" ] || echo "$ic_v"
  done
  return 0
}

# running_line <new-cdhash> <running-cdhash> <version>
# What the script says about the running driver: <new-cdhash> is the CDHash of the driver it just
# installed (version <version>), <running-cdhash> the one of the RMNetDriver in the registry (empty
# when none is attached). An empty <new-cdhash> means the new build could not be read, which says
# nothing about which build is running.
running_line() {
  if [ -z "$2" ]; then
    echo "no RMNetDriver attached (modem not attached in QMI mode?)"
  elif [ -z "$1" ]; then
    echo "cannot read the CDHash of version $3; whether it is the running driver is not known"
  elif [ "$2" = "$1" ]; then
    echo "version $3 is the running driver"
  else
    echo "an older build is still running; version $3 loads when the modem re-enumerates"
    echo "(unplug it, or send AT+CFUN=1,1)"
  fi
}

# ipv6_only_preferred_line <the built driver's Info.plist> <configured value: 0 or 1>
# Succeeds, printing nothing, when the plist has at least one RMNetDriver personality (IOUserClass
# RMNetDriver), each of them has RMNetIPv6OnlyPreferred, an integer equal to the configured value, and
# any other personality that has the key has it equal too. Otherwise prints one line saying what is
# wrong, naming every personality that is (with "none" for a missing key and "not an integer" for one
# of another type), and fails: a build with even one personality left at another value would match
# that model with the setting the owner did not choose. Personalities are named in byte order.
ipv6_only_preferred_line() {
  if ! ic_names=$(plutil -extract IOKitPersonalities raw -expect dictionary -o - "$1" 2>/dev/null); then
    echo "$1 has no IOKitPersonalities dictionary that can be read"
    return 1
  fi
  ic_names=$(printf '%s\n' "$ic_names" | LC_ALL=C sort)
  ic_drivers=0
  ic_wrong=
  while IFS= read -r ic_name; do
    [ -n "$ic_name" ] || continue
    case $ic_name in
      *.*)
        ic_wrong="$ic_wrong, $ic_name (a name with a '.', which plutil cannot reach)"
        continue
        ;;
    esac
    ic_key=IOKitPersonalities.$ic_name.RMNetIPv6OnlyPreferred
    ic_class=$(plutil -extract "IOKitPersonalities.$ic_name.IOUserClass" raw -expect string -o - "$1" 2>/dev/null) ||
      ic_class=
    if [ "$ic_class" = RMNetDriver ]; then
      ic_drivers=$((ic_drivers + 1))
    elif ! plutil -extract "$ic_key" raw -o - "$1" >/dev/null 2>&1; then
      continue  # not a driver personality, and without the key
    fi
    if ! plutil -extract "$ic_key" raw -o - "$1" >/dev/null 2>&1; then
      ic_value=none
    elif ! ic_value=$(plutil -extract "$ic_key" raw -expect integer -o - "$1" 2>/dev/null); then
      ic_value="not an integer"
    fi
    [ "$ic_value" = "$2" ] || ic_wrong="$ic_wrong, $ic_name $ic_value"
  done <<IC_NAMES
$ic_names
IC_NAMES
  if [ "$ic_drivers" -eq 0 ]; then
    echo "$1 has no RMNetDriver personality"
    return 1
  fi
  if [ -n "$ic_wrong" ]; then
    echo "RMNetIPv6OnlyPreferred is not $2 (as configured) in every personality of $1:${ic_wrong#,}"
    return 1
  fi
  return 0
}
