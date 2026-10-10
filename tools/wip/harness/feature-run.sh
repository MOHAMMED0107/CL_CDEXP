#!/usr/bin/env bash
# Run one feature function against a fake phone.
# Usage: feature-run.sh <feature.sh> <function> <fakebin-dir>
#   stdin is passed through (for y/N answers); set TEST_HOME to keep $HOME files between runs.
# It builds: phone-pro.sh up to (not including) the menu loop, i.e. all shared helpers
# (ash, setg, pkgs_only, comps_to_pkgs, bfield, sysnum, to_mah, TMPD, ...), then the feature file,
# then a call to <function>.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAIN="$HERE/../phone-pro.sh"
feat=$1; fn=$2; bin=$3
tmp=$(mktemp -d)
mkdir -p "$tmp/home"
awk '/^# ==== startup ====$/ || /^while true; do$/ { exit } { print }' "$MAIN" >"$tmp/run.sh"
cat "$feat" >>"$tmp/run.sh"
printf '\n%s\n' "$fn" >>"$tmp/run.sh"
PATH="$bin:$PATH" HOME="${TEST_HOME:-$tmp/home}" bash "$tmp/run.sh"
rc=$?
rm -rf "$tmp"
exit $rc
