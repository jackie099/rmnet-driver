# The build's identity: the paid Apple Developer team that signs it and the app's bundle ID (the
# driver's is <bundle ID>.driver), and whether the driver is built with IPv6-only preferred on (its
# RMNetIPv6OnlyPreferred, core/src/dhcp.cpp), from config.local in the repository root (copied
# from config.example; git-ignored) or from the environment variables of the same names, which win
# (an empty one counts as not set). Sourced from the repository root (`. ./scripts/config.sh`) by
# scripts/install-driver.sh, scripts/soak.sh and scripts/driver-log.sh, and by
# tests/scripts/test-config.sh (`make script-test`). Functions only: sourcing this file runs nothing.
# Their variables start with cfg_, so they do not change the caller's.
#
# config.local is data, never code: it is read line by line and never sourced. Only lines
# RMNET_TEAM_ID=<value>, RMNET_BUNDLE_ID=<value> and RMNET_IPV6_ONLY_PREFERRED=<value> count, with
# one pair of surrounding single or double quotes removed from the value; comments (# after any
# blanks) and blank lines are skipped; any other line is an error naming its number. A team ID must
# match ^[A-Z0-9]{10}$, a bundle ID ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ and RMNET_IPV6_ONLY_PREFERRED
# ^[01]$, so a $, a backtick, a blank, a quote or a slash never passes.
#
#   rmnet_config          sets TEAM_ID (empty when not set), BUNDLE_ID (io.rmnetdriver.RMNet when
#                         not set), DRIVER_ID ($BUNDLE_ID.driver) and IPV6_ONLY_PREFERRED (0 when
#                         not set, else 0 or 1): for the scripts that only observe the driver.
#   rmnet_config_require  the same, then refuses unless both IDs are set: for a signed build.
#
# On a malformed config.local, an invalid ID or RMNET_IPV6_ONLY_PREFERRED, or
# (rmnet_config_require) an ID not set, either prints one line to stderr, "config: <what is wrong>; copy config.example to config.local and fill it in",
# and returns 2.

# cfg_fail <what is wrong>: the error line; returns 2.
cfg_fail() {
  echo "config: $1; copy config.example to config.local and fill it in" >&2
  return 2
}

# cfg_matches <value> <extended regular expression>: whether the value is one line and matches.
cfg_matches() {
  case $1 in
    *'
'*) return 1 ;;
  esac
  printf '%s\n' "$1" | LC_ALL=C grep -Eq -- "$2"
}

# cfg_load: sets cfg_team, cfg_bundle and cfg_v6only (empty when not set) from config.local and the
# environment, and checks the ones set.
cfg_load() {
  cfg_team= cfg_bundle= cfg_v6only= cfg_team_from= cfg_bundle_from= cfg_v6only_from=
  if [ -e config.local ]; then
    if [ ! -f config.local ] || [ ! -r config.local ]; then
      cfg_fail "config.local is not a readable file"
      return 2
    fi
    cfg_n=0
    while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
      cfg_n=$((cfg_n + 1))
      case ${cfg_line#"${cfg_line%%[![:space:]]*}"} in
        '' | '#'*) continue ;;
      esac
      cfg_value=${cfg_line#*=}
      case $cfg_value in
        \"*\" | \'*\')
          cfg_value=${cfg_value#?}
          cfg_value=${cfg_value%?}
          ;;
      esac
      case $cfg_line in
        RMNET_TEAM_ID=*) cfg_team=$cfg_value cfg_team_from="in config.local" ;;
        RMNET_BUNDLE_ID=*) cfg_bundle=$cfg_value cfg_bundle_from="in config.local" ;;
        RMNET_IPV6_ONLY_PREFERRED=*) cfg_v6only=$cfg_value cfg_v6only_from="in config.local" ;;
        *)
          cfg_fail "config.local line $cfg_n is not RMNET_TEAM_ID=<value>, RMNET_BUNDLE_ID=<value>, RMNET_IPV6_ONLY_PREFERRED=<value>, a comment or a blank line"
          return 2
          ;;
      esac
    done <config.local
  fi
  if [ -n "${RMNET_TEAM_ID:-}" ]; then
    cfg_team=$RMNET_TEAM_ID cfg_team_from="from the environment"
  fi
  if [ -n "${RMNET_BUNDLE_ID:-}" ]; then
    cfg_bundle=$RMNET_BUNDLE_ID cfg_bundle_from="from the environment"
  fi
  if [ -n "${RMNET_IPV6_ONLY_PREFERRED:-}" ]; then
    cfg_v6only=$RMNET_IPV6_ONLY_PREFERRED cfg_v6only_from="from the environment"
  fi
  if [ -n "$cfg_team" ] && ! cfg_matches "$cfg_team" '^[A-Z0-9]{10}$'; then
    cfg_fail "RMNET_TEAM_ID $cfg_team_from is not a team ID (10 capital letters and digits)"
    return 2
  fi
  if [ -n "$cfg_bundle" ] && ! cfg_matches "$cfg_bundle" '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'; then
    cfg_fail "RMNET_BUNDLE_ID $cfg_bundle_from is not a bundle ID (letters, digits and hyphens, in two or more parts separated by dots)"
    return 2
  fi
  if [ -n "$cfg_v6only" ] && ! cfg_matches "$cfg_v6only" '^[01]$'; then
    cfg_fail "RMNET_IPV6_ONLY_PREFERRED $cfg_v6only_from is not 0 or 1"
    return 2
  fi
  return 0
}

rmnet_config() {
  cfg_load || return 2
  TEAM_ID=$cfg_team
  BUNDLE_ID=${cfg_bundle:-io.rmnetdriver.RMNet}
  DRIVER_ID=$BUNDLE_ID.driver
  IPV6_ONLY_PREFERRED=${cfg_v6only:-0}
}

rmnet_config_require() {
  rmnet_config || return 2
  if [ -z "$cfg_team" ] && [ -z "$cfg_bundle" ]; then
    cfg_fail "RMNET_TEAM_ID and RMNET_BUNDLE_ID are not set"
  elif [ -z "$cfg_team" ]; then
    cfg_fail "RMNET_TEAM_ID is not set"
  elif [ -z "$cfg_bundle" ]; then
    cfg_fail "RMNET_BUNDLE_ID is not set"
  fi
}
