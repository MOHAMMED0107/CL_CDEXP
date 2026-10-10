#!/usr/bin/env bash
# Tests for the free-space feature (feature.sh, entry function free_space).
# Runs the feature through the shared harness against a fake adb (test/bin/adb) that emulates a
# Redmi Note 9 Pro on Android 12 / MIUI 14. Exits 0 only if every test passes.
# KEEP_WORK=1 keeps test/.work for inspection.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FEAT_DIR=$(cd "$HERE/.." && pwd)
FEATURE="$FEAT_DIR/feature.sh"
SCRATCH=$(cd "$FEAT_DIR/../.." && pwd)
HARNESS="$SCRATCH/harness/feature-run.sh"
MAIN="$SCRATCH/phone-pro.sh"
BIN="$HERE/bin"
WORK="$HERE/.work"
TAB=$(printf '\t')
TODAY=$(date +%Y%m%d)
rm -rf "$WORK"
mkdir -p "$WORK"
[ "${KEEP_WORK:-0}" = 1 ] || trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
empty() { [ ! -s "$1" ]; }
lines() { [ "$(awk 'END { print NR }' "$1" 2>/dev/null)" = "$2" ]; }
same_set() { [ "$(LC_ALL=C sort "$1")" = "$(LC_ALL=C sort "$2")" ]; }
no_shell_errors() { ! grep -qE 'unbound variable|syntax error|command not found|awk: |mawk: |gawk: |bad substitution|No such file or directory' "$1"; }

# Copy a fixture set, turning @EXP20@/@EXP28@ into "now + 20/28 days" (trash expiry times).
prep() {
  local mode=$1 d="$WORK/fx-$1" now
  mkdir -p "$d"
  cp "$HERE/fixtures/$mode/"* "$d/"
  now=$(date +%s)
  sed -e "s/@EXP20@/$((now + 20 * 86400))/g" -e "s/@EXP28@/$((now + 28 * 86400))/g" \
    "$HERE/fixtures/$mode/files.txt" >"$d/files.txt"
  echo "$d"
}

# run NAME FIXTURES STATE HOME CWD ANSWERS [EXTRA_PATH]   (ANSWERS "-" means no input at all)
run() {
  local name=$1 fx=$2 state=$3 home=$4 cwd=$5 answers=$6 extra=${7:-}
  mkdir -p "$state" "$home" "$cwd"
  (
    cd "$cwd" || exit 99
    export FAKE_FIXTURES="$fx" FAKE_STATE="$state" TEST_HOME="$home"
    [ -z "$extra" ] || PATH="$extra:$PATH"
    if [ "$answers" = "-" ]; then
      "$HARNESS" "$FEATURE" free_space "$BIN" </dev/null
    else
      printf '%b' "$answers" | "$HARNESS" "$FEATURE" free_space "$BIN"
    fi
  ) >"$WORK/$name.out" 2>&1
  echo $? >"$WORK/$name.rc"
}
rc_is() { [ "$(cat "$WORK/$1.rc")" = "$2" ]; }

# Everything the happy-path run may delete (and nothing else).
expected_deleted() {
  local fx=$1
  {
    grep -F '/.trashed-' "$fx/files.txt" | sed 's/^[0-9]* //'
    printf '%s\n' \
      "/sdcard/MIUI/Gallery/cloud/.trashBin/a8f1c2e4b9d7.jpg" \
      "/sdcard/MIUI/Gallery/cloud/.trashBin/0c3b77e1f2a9.jpg" \
      "/sdcard/Download/WhatsApp_Plus_v17.60.apk" \
      "/sdcard/Download/Mum's game.apk" \
      "/sdcard/Download/Telegram/Telegram X 0.26.apk" \
      "/sdcard/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents/Sent/game.apk" \
      "/sdcard/Android/data/org.telegram.messenger/files/Telegram/Telegram Documents/MiXplorer_v6.64.apk" \
      "/sdcard/Android/media/com.whatsapp/WhatsApp/Databases/msgstore-2024-10-08.1.db.crypt14" \
      "/sdcard/Android/media/com.whatsapp/WhatsApp/Databases/msgstore-2024-10-07.1.db.crypt14" \
      "/sdcard/Android/media/com.whatsapp/WhatsApp/Databases/msgstore-2024-10-06.1.db.crypt14" \
      "/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Databases/msgstore-2024-10-08.1.db.crypt14" \
      "/sdcard/Android/data/com.empty.leftover" \
      "/sdcard/Android/data/com.example.uninstalled" \
      "/sdcard/Android/data/com.old.game" \
      "/sdcard/Android/media/com.oldapp.recorder" \
      "/sdcard/MIUI/debug_log/powerinfo/power_2024-10-01.log" \
      "/sdcard/MIUI/debug_log/.mqsas/mqs_2024-10-02.txt"
  }
}
# Of those, the ones copied to the computer first (trash, installers, WhatsApp, folders).
expected_copied() {
  expected_deleted "$1" | grep -v -e '/MIUI/Gallery/' -e '/MIUI/debug_log/'
}

# Answers for the happy path: cache y | trash y,copy y | MIUI bin y,copy n | installers y,copy y |
# WhatsApp y,copy y | left-behind folders y,copy y | MIUI logs y,copy n
HAPPY_ANSWERS='y\ny\ny\ny\nn\ny\ny\ny\ny\ny\ny\ny\nn\n'
NO_ANSWERS='\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n'

# ------------------------------------------------------------------------------------------
echo "== 1. Static checks (bash 3.2 / portable tools / feature contract) =="
check "feature.sh has valid bash syntax" bash -n "$FEATURE"
check "fake adb has valid bash syntax" bash -n "$BIN/adb"

# Sourcing must define things only: no output, no commands, only fs_* names (plus free_space).
env -i HOME="$WORK/srchome" PATH="/usr/bin:/bin" bash -c '
  set -u
  compgen -A function | sort >"$1/f.before"; compgen -A variable | sort >"$1/v.before"
  trap '\''echo "$BASH_COMMAND" >>"$1/cmds"'\'' DEBUG
  . "$2"
  trap - DEBUG
  compgen -A function | sort >"$1/f.after"; compgen -A variable | sort >"$1/v.after"
' _ "$WORK" "$FEATURE" >"$WORK/source.out" 2>&1
check "sourcing feature.sh prints nothing" empty "$WORK/source.out"
comm -13 "$WORK/f.before" "$WORK/f.after" >"$WORK/f.new"
comm -13 "$WORK/v.before" "$WORK/v.after" | grep -v -e '^BASH' -e '^_$' >"$WORK/v.new"
check "free_space is defined" grep -qx free_space "$WORK/f.new"
check "every other new function starts with fs_" sh -c '! grep -v -e "^fs_" -e "^free_space$" "$1"' _ "$WORK/f.new"
check "every new global variable starts with fs_" sh -c '! grep -v "^fs_" "$1"' _ "$WORK/v.new"
grep -v -e '^\. ' -e '^trap ' "$WORK/cmds" >"$WORK/cmds.other" 2>/dev/null
check "top level only assigns constants (no commands run)" sh -c '! grep -v -E "^fs_[a-z_]+=" "$1"' _ "$WORK/cmds.other"

for pat in 'declare -A' 'mapfile' 'readarray' ',,}' '^^}' '&>>' 'sed -i' 'grep -P' 'date -d' 'readlink -f' 'sort -h' 'du -b' 'numfmt' 'timeout ' 'gensub' 'asort' 'strftime' 'systime' '\y' 'grep -m' 'local -n' '${!'; do
  check "no '$pat' in feature.sh" hasnt "$FEATURE" "$pat"
done
grep -n 'while' "$FEATURE" | grep 'read' | grep -v '<&3' >"$WORK/loops"
check "every while-read loop reads from fd 3" empty "$WORK/loops"
grep -n 'stat -c' "$FEATURE" | grep -v -e '^[0-9]*:fs_cmd_' -e '^[0-9]*: *#' >"$WORK/statc"
check "stat -c is only used in on-phone commands" empty "$WORK/statc"

# ------------------------------------------------------------------------------------------
echo "== 2. Happy path: clear cache, report, delete each junk kind (copies + failures) =="
FX=$(prep happy)
S="$WORK/happy/state"; H="$WORK/happy/home"; C="$WORK/happy/cwd"
run happy "$FX" "$S" "$H" "$C" "$HAPPY_ANSWERS"
O="$WORK/happy.out"
check "exit code 0" rc_is happy 0
check "only known adb commands were sent" empty "$S/unknown"
check "no shell or awk errors" no_shell_errors "$O"
check "storage before shown in GB" has "$O" "Used: 82.6 GB   Free: 22.8 GB   Total: 105.4 GB   (79% full)"
check "cache size from diskstats shown" has "$O" "Android's last measurement: about 2.1 GB of temporary cache."
check "pm trim-caches was run first" sh -c '[ "$(head -n 1 "$1")" = trim-caches ]' _ "$S/changes"
check "space that came back is measured with df" has "$O" "Space that came back: 1.8 GB   (free now: 24.5 GB)"
check "DCIM size" grep -qE 'Camera photos and videos \(DCIM\) +2\.9 GB' "$O"
check "Screenshots size (DCIM/Screenshots)" grep -qE 'Screenshots \(already counted above\) +2 MB' "$O"
check "WhatsApp media size (Android 11+ and legacy paths)" grep -qE 'WhatsApp photos, videos and voice notes +103 MB' "$O"
check "Telegram size" grep -qE 'Telegram +129 MB' "$O"
check "total app size from diskstats (app + data)" grep -qE 'Apps and their data \(all apps together\) +28\.4 GB' "$O"
check "biggest app listed" has "$O" "4.9 GB  com.whatsapp"
check "10 biggest files listed, biggest first" sh -c 'grep -A1 "The 10 biggest files" "$1" | grep -q "1.9 GB  DCIM/Camera/VID_20240901_101500.mp4"' _ "$O"
check "big file with spaces in its name" has "$O" "150 MB  Movies/My Trip 2023.mp4"
check "exactly 10 big files" sh -c '[ "$(sed -n "/The 10 biggest files/,/Tips:/p" "$1" | grep -c "^  *[0-9.]* [MG]B  ")" = 10 ]' _ "$O"
check "trash: count + size" has "$O" "-- Android's trash (photos, videos and files you deleted): 3 files, 306 MB --"
check "trash: says it deletes itself anyway" has "$O" "(within 28 days anyway)"
check "MIUI Gallery bin found" has "$O" "-- MIUI Gallery recycle bin: 2 files, 6 MB --"
check "installer files: 6 found (.pending download ignored)" has "$O" "-- Leftover app installer files (.apk) in Download, WhatsApp and Telegram: 6 files, 144 MB --"
check "in-progress download is never listed" hasnt "$O" "NewApp.apk"
check "WhatsApp: 4 old backups" has "$O" "-- Old WhatsApp daily chat backups: 4 files, 127 MB --"
check "WhatsApp: newest backup kept" has "$O" "Always kept (newest backup): Android/media/com.whatsapp/WhatsApp/Databases/msgstore.db.crypt14"
check "WhatsApp: folder without newest backup left alone" has "$O" "Left alone: WhatsApp/Databases has old backups but no newest backup"
check "left-behind folders: 4 found" has "$O" "-- Folders left behind by apps you removed: 4 folders, 404 MB --"
check "chat app folder protected even if app is gone" has "$O" "Kept on purpose: Android/media/com.whatsapp.w4b"
check "MIUI debug logs found" has "$O" "-- MIUI debug logs (MIUI/debug_log): 3 files, 6 MB --"
check "failed copy keeps the file on the phone" has "$O" "Could not copy Download/Some App (1).apk, so it was kept on the phone."
check "failed delete reported" has "$O" "1 could not be deleted (the phone refused)"
check "deleting without a copy says it cannot be undone" has "$O" "This cannot be undone."
expected_deleted "$FX" >"$WORK/happy.expected"
check "deleted exactly the expected 20 items, nothing else" same_set "$S/deleted" "$WORK/happy.expected"
check "no delete of a path that did not exist" empty "$S/rm_missing"
expected_copied "$FX" >"$WORK/happy.copied"
cut -f1 "$S/pulls" >"$WORK/happy.pulled"
check "copied exactly the 16 items asked for" same_set "$WORK/happy.pulled" "$WORK/happy.copied"
check "copies are complete files in ./phone-junk-DATE" sh -c '
  [ "$(wc -c <"$1/phone-junk-'"$TODAY"'/sdcard/Download/Mum'"'"'s game.apk" | tr -d " ")" = 18874368 ] &&
  [ -f "$1/phone-junk-'"$TODAY"'/sdcard/Android/data/com.old.game/files/res/level1.pak" ] &&
  [ -d "$1/phone-junk-'"$TODAY"'/sdcard/Android/data/com.empty.leftover" ]' _ "$C"
check "every copied item was copied before it was deleted" awk '
  /^pull / { p = substr($0, 6); sub(/ phone-junk-.*$/, "", p); pulled[p] = NR }
  /^shell rm / { for (x in pulled) if (index($0, x) && pulled[x] > NR) bad = 1 }
  END { exit bad }' "$S/calls"
check "undo file lists the 16 copies" lines "$H/phone-pro-free-space-undo.txt" 16
check "undo file rows: base, copy, phone path, kind, bytes" awk -F'\t' -v c="$C" 'NF != 5 || $1 != c || $2 !~ /^phone-junk-/ || $3 !~ /^\/sdcard\// || ($4 != "f" && $4 != "d") || $5 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' "$H/phone-pro-free-space-undo.txt"
check "log lists the 20 deleted items" lines "$H/phone-pro-free-space-log.txt" 20
check "summary shows junk freed and new free space" sh -c 'grep -q "Hidden junk deleted: 962 MB." "$1" && grep -q "Free space now: 25.5 GB of 105.4 GB (it was 22.8 GB at the start)." "$1"' _ "$O"
cp "$H/phone-pro-free-space-undo.txt" "$WORK/undo.saved"
cp "$S/changes" "$WORK/changes.saved"

# ------------------------------------------------------------------------------------------
echo "== 3. Pressing Enter / No to everything changes nothing =="
for variant in enter no eof; do
  case $variant in
    enter) ans=$NO_ANSWERS ;;
    no) ans='n\nN\nno\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\n' ;;
    eof) ans=- ;;
  esac
  S2="$WORK/$variant/state"; H2="$WORK/$variant/home"; C2="$WORK/$variant/cwd"
  run "$variant" "$FX" "$S2" "$H2" "$C2" "$ans"
  check "[$variant] exit code 0" rc_is "$variant" 0
  check "[$variant] only known adb commands" empty "$S2/unknown"
  check "[$variant] nothing changed on the phone (no trim, rm or push)" empty "$S2/changes"
  check "[$variant] nothing copied" empty "$S2/pulls"
  check "[$variant] no undo or log file, no junk folder" sh -c '[ ! -e "$1/phone-pro-free-space-undo.txt" ] && [ ! -e "$1/phone-pro-free-space-log.txt" ] && [ -z "$(ls -A "$2")" ]' _ "$H2" "$C2"
  check "[$variant] cache step skipped" has "$WORK/$variant.out" "  Skipped."
  check "[$variant] all 6 junk kinds kept" sh -c '[ "$(grep -c "^   Kept\.$" "$1")" = 6 ]' _ "$WORK/$variant.out"
  check "[$variant] summary says nothing deleted" has "$WORK/$variant.out" "No junk was deleted."
  check "[$variant] report still shown" has "$WORK/$variant.out" "The 10 biggest files (over 10 MB):"
done

# ------------------------------------------------------------------------------------------
echo "== 4. Undo: put back what was copied =="
run undo-no "$FX" "$S" "$H" "$C" "$NO_ANSWERS"
check "[no] exit code 0" rc_is undo-no 0
check "[no] offer to put back was shown" has "$WORK/undo-no.out" "Earlier, 16 deleted item(s) (951 MB) were copied to this computer before deleting."
check "[no] undo file untouched" cmp -s "$H/phone-pro-free-space-undo.txt" "$WORK/undo.saved"
check "[no] phone untouched" cmp -s "$S/changes" "$WORK/changes.saved"
check "[no] explains how to stop the question" has "$WORK/undo-no.out" "To stop this question, delete this file:"

run undo-yes "$FX" "$S" "$H" "$C" "y\n$NO_ANSWERS"
O="$WORK/undo-yes.out"
check "[yes] exit code 0" rc_is undo-yes 0
check "[yes] only known adb commands" empty "$S/unknown"
check "[yes] all 16 put back" has "$O" "Put back 16 of 16 item(s)."
check "[yes] pushed exactly the 16 copied items to their old place" sh -c 'cut -f2 "$1" | LC_ALL=C sort >"$1.r"; [ "$(cat "$1.r")" = "$(LC_ALL=C sort "$2")" ]' _ "$S/pushes" "$WORK/happy.copied"
check "[yes] pushes used the saved copies" awk -F'\t' '$1 !~ /^phone-junk-[0-9]+\/sdcard\// { bad = 1 } END { exit bad }' "$S/pushes"
expected_deleted "$FX" | grep -e '/MIUI/Gallery/' -e '/MIUI/debug_log/' >"$WORK/still.deleted"
check "[yes] only items deleted without a copy are still gone" same_set "$S/deleted" "$WORK/still.deleted"
check "[yes] undo file removed after a full restore" test ! -e "$H/phone-pro-free-space-undo.txt"
tail -n +$(( $(awk 'END { print NR }' "$WORK/changes.saved") + 1 )) "$S/changes" >"$WORK/changes.new"
check "[yes] the only new phone changes are the 16 pushes" sh -c '[ "$(grep -vc "^push " "$1")" = 0 ] && [ "$(grep -c "^push " "$1")" = 16 ]' _ "$WORK/changes.new"
check "[yes] put-back trash shows up again (and is kept on Enter)" has "$O" "-- Android's trash (photos, videos and files you deleted): 3 files, 306 MB --"

# A copy that went missing on the computer: the rest is put back, that one stays listed.
S4="$WORK/partial/state"; H4="$WORK/partial/home"; C4="$WORK/partial/cwd"
run partial-setup "$FX" "$S4" "$H4" "$C4" "$HAPPY_ANSWERS"
rm -f "$C4/phone-junk-$TODAY/sdcard/Download/WhatsApp_Plus_v17.60.apk"
run partial "$FX" "$S4" "$H4" "$C4" "y\n$NO_ANSWERS"
check "[partial] exit code 0" rc_is partial 0
check "[partial] missing copy reported" has "$WORK/partial.out" "Copy not found, skipped: $C4/phone-junk-$TODAY/sdcard/Download/WhatsApp_Plus_v17.60.apk"
check "[partial] 15 of 16 put back" has "$WORK/partial.out" "Put back 15 of 16 item(s)."
check "[partial] the missing one stays listed for next time" sh -c 'lines() { [ "$(awk "END { print NR }" "$1")" = "$2" ]; }; lines "$1" 1 && grep -q "WhatsApp_Plus_v17.60.apk" "$1"' _ "$H4/phone-pro-free-space-undo.txt"
check "[partial] it is still deleted on the phone" grep -qx "/sdcard/Download/WhatsApp_Plus_v17.60.apk" "$S4/deleted"

# ------------------------------------------------------------------------------------------
echo "== 5. Unreadable / unsupported data (permission denied, no measurements, refused trim) =="
FXB=$(prep broken)
SB="$WORK/broken/state"
run broken "$FXB" "$SB" "$WORK/broken/home" "$WORK/broken/cwd" 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n'
O="$WORK/broken.out"
check "exit code 0 (no crash)" rc_is broken 0
check "only known adb commands" empty "$SB/unknown"
check "no shell or awk errors" no_shell_errors "$O"
check "unreadable df explained" has "$O" "Could not read the storage size from the phone (carrying on without it)."
check "refused cache clear explained" has "$O" "The phone refused to clear the cache over USB, so nothing was changed."
check "refusal reason shown in one line" has "$O" "Reason given: java.lang.SecurityException: Neither user 2000 nor current process has android.permission.CLEAR_APP_CACHE."
check "missing app measurements explained" has "$O" "App sizes: Android has not measured them yet"
check "unmeasurable folders explained" has "$O" "Could not measure the folders"
check "no big files explained" has "$O" "No files over 10 MB found (or the phone did not allow the search)."
check "empty trash reported" has "$O" "-- Android's trash (photos, videos and files you deleted): nothing found --"
check "MIUI bin not reachable explained" has "$O" "(Not found or not readable over USB."
check "unreadable app list: folder check skipped for safety" has "$O" "Could not read the list of installed apps, so this check was skipped to stay safe."
check "nothing deleted" empty "$SB/deleted"
check "nothing copied" empty "$SB/pulls"
check "only the (refused) trim was attempted" sh -c '[ "$(cat "$1")" = trim-caches ]' _ "$SB/changes"
check "summary still printed" has "$O" "No junk was deleted."
check "raw phone error text is not shown" hasnt "$O" "Failure calling service package"

FXC=$(prep clean)
SC="$WORK/clean/state"
run clean "$FXC" "$SC" "$WORK/clean/home" "$WORK/clean/cwd" "$NO_ANSWERS"
O="$WORK/clean.out"
check "[clean phone] exit code 0" rc_is clean 0
check "[clean phone] only known adb commands" empty "$SC/unknown"
check "[clean phone] no shell or awk errors" no_shell_errors "$O"
check "[clean phone] wrapped df line still read" has "$O" "Used: 82.6 GB   Free: 22.8 GB   Total: 105.4 GB   (79% full)"
check "[clean phone] empty per-app lists handled" sh -c 'grep -q "Apps and their data" "$1" && ! grep -q "Biggest apps" "$1"' _ "$O"
check "[clean phone] missing folders say not found" grep -qE 'Telegram +not found' "$O"
check "[clean phone] optional rows hidden" hasnt "$O" "WhatsApp Business photos"
check "[clean phone] Android/data refused: explained and skipped" has "$O" "Could not look inside Android/data (the phone did not allow it), so that part was skipped."
check "[clean phone] newest WhatsApp backup note even with nothing to delete" has "$O" "Always kept (newest backup): Android/media/com.whatsapp/WhatsApp/Databases/msgstore.db.crypt14"
check "[clean phone] all 6 junk kinds empty" sh -c '[ "$(grep -c ": nothing found --$" "$1")" = 6 ]' _ "$O"
check "[clean phone] nothing changed" empty "$SC/changes"
check "[clean phone] unchanged free space shown once" has "$O" "Free space now: 22.8 GB of 105.4 GB."

# ------------------------------------------------------------------------------------------
echo "== 6. Portable awk: same results with BWK awk (macOS) and gawk --posix =="
for impl in original-awk gawk; do
  if ! command -v "$impl" >/dev/null 2>&1; then echo "  skip $impl (not installed)"; continue; fi
  shim="$WORK/shim-$impl"
  mkdir -p "$shim"
  if [ "$impl" = gawk ]; then
    printf '#!/bin/sh\nexec gawk --posix "$@"\n' >"$shim/awk"
  else
    printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$impl")" >"$shim/awk"
  fi
  chmod +x "$shim/awk"
  # The fake adb runs with the same PATH, so it also gets this awk.
  S3="$WORK/awk-$impl/state"
  run "awk-$impl" "$FX" "$S3" "$WORK/awk-$impl/home" "$WORK/awk-$impl/cwd" "$HAPPY_ANSWERS" "$shim"
  check "[$impl] exit code 0" rc_is "awk-$impl" 0
  check "[$impl] only known adb commands" empty "$S3/unknown"
  check "[$impl] no awk errors" no_shell_errors "$WORK/awk-$impl.out"
  check "[$impl] deleted exactly the expected items" same_set "$S3/deleted" "$WORK/happy.expected"
  sed "s#$WORK/awk-$impl/#X/#g; s#$WORK/happy/#X/#g" "$WORK/awk-$impl.out" >"$WORK/awk-$impl.norm"
  sed "s#$WORK/happy/#X/#g" "$WORK/happy.out" >"$WORK/happy.norm"
  check "[$impl] output identical to mawk run" cmp -s "$WORK/awk-$impl.norm" "$WORK/happy.norm"
done

# ------------------------------------------------------------------------------------------
echo "== 7. No global variables leak out of free_space (everything is local or fs_*) =="
L="$WORK/leak"
mkdir -p "$L/state" "$L/home" "$L/cwd"
awk '/^while true; do$/ { exit } { print }' "$MAIN" >"$L/run.sh"
cat "$FEATURE" >>"$L/run.sh"
cat >>"$L/run.sh" <<'EOF'

compgen -A variable | sort >"$LEAK_DIR/before"
free_space
compgen -A variable | sort >"$LEAK_DIR/after"
EOF
( cd "$L/cwd" && printf '%b' "$HAPPY_ANSWERS" | LEAK_DIR="$L" FAKE_FIXTURES="$FX" FAKE_STATE="$L/state" HOME="$L/home" PATH="$BIN:$PATH" bash "$L/run.sh" ) >"$L/out" 2>&1
comm -13 "$L/before" "$L/after" | grep -v -e '^BASH' -e '^_$' >"$L/new"
check "free_space ran" has "$L/out" "== Summary =="
check "only fs_* globals were created" sh -c '! grep -v "^fs_" "$1"' _ "$L/new"

# ------------------------------------------------------------------------------------------
echo "== 8. On-phone commands: valid shell, and the fake answers like real find/stat/ls would =="
# Build the happy fixture as a real folder tree (sparse files), run the feature's exact command
# strings with dash + find/stat/ls on it, and compare with the fake adb's answers.
T="$WORK/sdtree"
while read -r size path <&3; do
  mkdir -p "$T$(dirname "$path")"
  dd if=/dev/zero of="$T$path" bs=1 count=0 seek="$size" 2>/dev/null
done 3<"$FX/files.txt"
while read -r d <&3; do mkdir -p "$T$d"; done 3<"$FX/dirs.txt"
getcmd() { HOME="$WORK" bash -c '. "$1"; eval "printf \"%s\" \"\$$2\""' _ "$FEATURE" "$1"; }
for v in fs_cmd_scan fs_cmd_miuibin fs_cmd_apk fs_cmd_wa fs_cmd_logs fs_cmd_lsdata fs_cmd_lsmedia; do
  cmd=$(getcmd "$v")
  local_cmd=$(printf '%s' "$cmd" | sed "s#/sdcard#$T/sdcard#g")
  ( cd / && dash -c "$local_cmd" ) | sed -e "s#$T##g" -e 's#//*#/#g' | LC_ALL=C sort >"$WORK/real.$v"
  FAKE_FIXTURES="$FX" FAKE_STATE="$WORK/xstate" "$BIN/adb" shell "$cmd" | tr -d '\r' | LC_ALL=C sort >"$WORK/fake.$v"
  check "$v: real tools and fake adb agree ($(awk 'END { print NR }' "$WORK/real.$v") lines)" cmp -s "$WORK/real.$v" "$WORK/fake.$v"
done
check "fake adb received no unknown commands here" sh -c '[ ! -s "$1/xstate/unknown" ]' _ "$WORK"
q=$(HOME="$WORK" bash -c '. "$1"; fs_q "$2"' _ "$FEATURE" "$T/sdcard/Download/Mum's game.apk")
out=$(dash -c "rm -f $q && [ ! -e $q ] && echo FS_GONE")
check "delete command quotes a name with an apostrophe correctly" sh -c '[ "$1" = FS_GONE ] && [ ! -e "$2" ] && [ -e "$3" ]' _ "$out" "$T/sdcard/Download/Mum's game.apk" "$T/sdcard/Download/Some App (1).apk"
q=$(HOME="$WORK" bash -c '. "$1"; fs_q "$2"' _ "$FEATURE" "$T/sdcard/Android/data/com.old.game")
out=$(dash -c "rm -rf $q && [ ! -e $q ] && echo FS_GONE")
check "folder delete removes only that folder" sh -c '[ "$1" = FS_GONE ] && [ ! -e "$2/com.old.game" ] && [ -e "$2/com.example.uninstalled" ]' _ "$out" "$T/sdcard/Android/data"

# ------------------------------------------------------------------------------------------
echo
echo "Passed: $pass   Failed: $fail"
[ "$fail" -eq 0 ]
