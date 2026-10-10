#!/usr/bin/env bash
# phone-pro.sh: safe Android power-user toolkit over USB (ADB), tuned for Redmi / MIUI.
# Run on YOUR computer (Windows: Git Bash; macOS; Linux) with the phone plugged in.
# Needs: adb (Android platform-tools). Optional: scrcpy.
# Phone setup (Redmi Note 9 Pro):
#   Settings > About phone > tap "MIUI version" 7 times.
#   Settings > Additional settings > Developer options > turn on:
#     - "USB debugging"                     (needed for everything)
#     - "USB debugging (Security settings)" (needed for options 2-5; asks for SIM + Mi account)
#   Plug in, unlock the phone and tap "Allow" on the USB debugging prompt.
set -u

# Windows Git Bash rewrites arguments that start with "/" (e.g. /sdcard -> C:/Program Files/Git/sdcard)
# before passing them to adb.exe. Turn that off so phone paths reach the phone unchanged.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

LOG="$HOME/phone-pro-removed.txt"         # apps removed by option 9, so option 10 can restore them
BATLOG="$HOME/phone-pro-battery-log.csv"  # one line per run of option 13

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. Install it first (see header)."; exit 1; }; }
need adb

if ! adb get-state >/dev/null 2>&1; then
  echo "No phone found. Check the cable, unlock the phone, and accept the 'Allow USB debugging' prompt."
  adb devices
  exit 1
fi

TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t phonepro)
trap 'rm -rf "$TMPD"' EXIT

# </dev/null stops adb from swallowing the menu's keyboard input.
ash() { adb shell "$@" </dev/null | tr -d '\r'; }

# Keep only lines that are valid package names.
pkgs_only() { grep -E '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'; }
# "pkg/Class:pkg2/Class2" (how Android stores enabled services) -> one package per line.
comps_to_pkgs() { tr ': ' '\n\n' | sed 's#/.*##' | pkgs_only; }

# Change a global setting and read it back, because MIUI silently refuses without the Security settings toggle.
setg() {
  ash settings put global "$1" "$2" >/dev/null 2>&1
  if [ "$(ash settings get global "$1")" != "$2" ]; then
    echo "Could not change $1."
    echo "Turn on 'USB debugging (Security settings)' in Developer options (needs a SIM and Mi account), then try again."
    return 1
  fi
}

health() {
  echo "== Device =="
  echo "Model:   $(ash getprop ro.product.manufacturer) $(ash getprop ro.product.model)"
  echo "Android: $(ash getprop ro.build.version.release) (security patch $(ash getprop ro.build.version.security_patch))"
  echo "MIUI:    $(ash getprop ro.miui.ui.version.name) $(ash getprop ro.build.version.incremental)"
  echo
  echo "== Battery =="
  ash dumpsys battery | grep -E 'level|temperature|health|status' | sed 's/^ */  /'
  echo "  (temperature is in tenths of a degree C, e.g. 312 = 31.2C; health 2 = Good)"
  echo
  echo "== Storage =="
  ash df -h /data | sed 's/^/  /'
  echo
  echo "== Apps you installed: $(ash pm list packages -3 | wc -l | tr -d ' ') =="
}

faster() {
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    setg "$k" 0.5 || return
  done
  echo "Animations set to 0.5x: the phone will feel noticeably snappier. Undo: option 3."
}

reset_anim() {
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    setg "$k" 1 || return
  done
  echo "Animations restored to 1x."
}

adblock_dns() {
  setg private_dns_mode hostname || return
  setg private_dns_specifier dns.adguard-dns.com || return
  echo "Private DNS set to AdGuard: blocks most ads and trackers in every app and browser."
  echo "Undo: option 5, or Settings > Connection & sharing > Private DNS > Off."
}

dns_off() {
  setg private_dns_mode opportunistic && echo "Private DNS back to Automatic."
}

list_apps() {
  echo "Pre-installed apps whose name hints at bloat (review before removing anything):"
  matches=$(ash pm list packages -s | sed 's/package://' \
    | grep -Ei 'facebook|netflix|linkedin|spotify|booking|amazon|tiktok|candy|bixby|glance|miui\.msa|analytics')
  if [ -n "$matches" ]; then echo "$matches" | sed 's/^/  /'; else echo "  none matched"; fi
  echo
  echo "To remove one for your user only (the app stays in the system image, so this is reversible):"
  echo "  adb shell pm uninstall --user 0 <package>"
  echo "To bring it back:"
  echo "  adb shell cmd package install-existing <package>"
  echo "Never remove anything with 'systemui', 'launcher', 'phone', 'telephony', 'settings' or 'google.android.gms' in the name."
}

# Redmi / MIUI junk that is commonly removed without side effects. Each one is asked about first.
# Deliberately NOT here (removing them can break MIUI or cause a boot loop):
#   com.miui.securitycenter, com.miui.home, com.miui.system, com.xiaomi.finddevice, com.miui.powerkeeper, com.xiaomi.joyose
MIUI_JUNK=(
  "com.miui.msa.global|MIUI System Ads, the main source of ads inside MIUI"
  "com.miui.analytics|Xiaomi usage tracking"
  "com.miui.android.fashiongallery|Wallpaper Carousel (lock-screen ads)"
  "com.miui.hybrid|Quick Apps (ad-driven mini apps)"
  "com.miui.hybrid.accessory|Quick Apps helper"
  "com.miui.yellowpage|Yellow Pages"
  "com.xiaomi.glgm|Xiaomi Games"
  "com.facebook.appmanager|Facebook App Manager"
  "com.facebook.services|Facebook Services"
  "com.facebook.system|Facebook App Installer"
  "com.netflix.partner.activation|Netflix partner activation"
  "com.miui.bugreport|MIUI Feedback"
  "com.xiaomi.mipicks|GetApps store (constant promo notifications)"
  "com.mi.android.globalminusscreen|App Vault, the left-most home screen"
  "com.mi.globalbrowser|Mi Browser (only if you use Chrome or another browser)"
  "com.miui.videoplayer|Mi Video (only if you use another video player)"
  "com.miui.player|Mi Music (only if you use another music app)"
)

redmi_debloat() {
  echo "You'll be asked about each app. Just pressing Enter means No."
  echo "Removed apps are saved to $LOG so option 10 can bring them all back."
  echo "Tip: run option 7 (backup) first if you haven't already."
  installed=$(ash pm list packages | sed 's/package://')
  found=0
  for entry in "${MIUI_JUNK[@]}"; do
    pkg=${entry%%|*}
    desc=${entry#*|}
    grep -qx "$pkg" <<<"$installed" || continue
    found=1
    read -r -p "Remove $desc [$pkg]? [y/N] " a
    if [[ $a =~ ^[Yy]$ ]]; then
      if ash pm uninstall --user 0 "$pkg" | grep -q Success; then
        echo "$pkg" >>"$LOG"
        echo "  removed"
      else
        echo "  could not remove (left as is)"
      fi
    fi
  done
  [ "$found" = 1 ] || echo "None of the known MIUI junk apps are installed. Nice and clean already."
}

restore_removed() {
  if [ ! -s "$LOG" ]; then
    echo "Nothing to restore: $LOG is empty or missing."
    return
  fi
  failed=()
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    if ash cmd package install-existing "$pkg" | grep -q installed; then
      echo "  restored $pkg"
    else
      echo "  failed   $pkg"
      failed+=("$pkg")
    fi
  done < <(sort -u "$LOG")
  if [ "${#failed[@]}" -gt 0 ]; then printf '%s\n' "${failed[@]}" >"$LOG"; else rm -f "$LOG"; fi
}

backup_media() {
  dest="phone-backup-$(date +%Y%m%d)"
  mkdir -p "$dest"
  for d in DCIM Pictures Documents Download; do
    echo "Copying /sdcard/$d ..."
    adb pull "/sdcard/$d" "$dest/" </dev/null >/dev/null 2>&1 && echo "  done" || echo "  skipped (not found)"
  done
  echo "Backup saved to: $(pwd)/$dest"
}

mirror() {
  if command -v scrcpy >/dev/null 2>&1; then
    scrcpy --stay-awake --turn-screen-off
  else
    echo "Install scrcpy (https://github.com/Genymobile/scrcpy) to control your phone from your PC keyboard and mouse."
  fi
}

# ---------- Option 11: privacy audit ----------
# Inputs: apps ("pkg installer", apps you installed), grants ("pkg PERMISSION" granted at runtime),
#         special ("CATEGORY pkg" for accessibility, notification access, device admin, installing apps).
AUDIT_AWK='
function src(p) {
  if (!(p in inst)) return "system app"
  if (inst[p] == "com.android.vending") return "Play Store"
  if (inst[p] ~ /^com\.xiaomi\.(mipicks|market|discover)$/) return "Xiaomi GetApps"
  return "NOT from an app store"
}
function add(k, p) {
  if ((k, p) in has) return
  has[k, p] = 1
  list[k] = list[k] " " p
  if (src(p) == "NOT from an app store" && !(p in flagged)) { order[++nf] = p; flagged[p] = 1 }
}
BEGIN {
  n = 0
  n++; key[n] = "ACCESSIBILITY";              short[key[n]] = "sees your screen";        title[n] = "Accessibility: can see your screen and tap for you (highest risk)"
  n++; key[n] = "NOTIFICATIONS";              short[key[n]] = "reads notifications";     title[n] = "Notification access: can read every notification, including OTP codes"
  n++; key[n] = "DEVICE_ADMIN";               short[key[n]] = "device admin";            title[n] = "Device admin: can stop itself from being uninstalled"
  n++; key[n] = "INSTALL_APPS";               short[key[n]] = "installs apps";           title[n] = "Can install other apps"
  n++; key[n] = "READ_SMS";                   short[key[n]] = "reads SMS";               title[n] = "Read your SMS, including OTP codes"
  n++; key[n] = "SEND_SMS";                   short[key[n]] = "sends SMS";               title[n] = "Send SMS (can cost you money)"
  n++; key[n] = "READ_CONTACTS";              short[key[n]] = "contacts";                title[n] = "Read your contacts"
  n++; key[n] = "READ_CALL_LOG";              short[key[n]] = "call history";            title[n] = "Read your call history"
  n++; key[n] = "ACCESS_BACKGROUND_LOCATION"; short[key[n]] = "background location";     title[n] = "Track your location even when the app is closed"
  n++; key[n] = "ACCESS_FINE_LOCATION";       short[key[n]] = "precise location";        title[n] = "See your precise location"
  n++; key[n] = "RECORD_AUDIO";               short[key[n]] = "microphone";              title[n] = "Use the microphone"
  n++; key[n] = "CAMERA";                     short[key[n]] = "camera";                  title[n] = "Use the camera"
  alias["RECEIVE_SMS"] = "READ_SMS"
}
FILENAME == ARGV[1] { inst[$1] = $2; next }
FILENAME == ARGV[2] { k = ($2 in alias) ? alias[$2] : $2; if (($1 in inst) && (k in short)) add(k, $1); next }
($1 in short) { add($1, $2) }
END {
  print "== Privacy audit, " today " =="
  print "Which apps can reach your private data, and where each app came from."
  for (i = 1; i <= n; i++) {
    k = key[i]
    print ""
    print "-- " title[i] " --"
    if (list[k] == "") { print "   (no apps)"; continue }
    m = split(substr(list[k], 2), arr, " ")
    for (j = 1; j <= m; j++) printf "   %-45s %s\n", arr[j], src(arr[j])
  }
  print ""
  print "== Worth a closer look =="
  if (nf == 0) {
    print "   Nothing suspicious: every app with sensitive access came from the Play Store, Xiaomi GetApps or the system."
  } else {
    for (j = 1; j <= nf; j++) {
      p = order[j]; why = ""
      for (i = 1; i <= n; i++) if ((key[i], p) in has) why = why (why == "" ? "" : ", ") short[key[i]]
      printf "   %s (NOT from an app store): %s\n", p, why
    }
    print "   If you do not recognise one of these, uninstall it. If you do, make sure you trust where it came from."
    print "   (Apps that came pre-installed by Xiaomi can also show up here.)"
  }
  print ""
  print "To take access away: in Settings, search for \"Accessibility\", \"Notification access\","
  print "\"Device admin apps\" or \"Install unknown apps\"; for the rest go to"
  print "Settings > Apps > Manage apps > (the app) > App permissions."
  print "MIUI also keeps its own extra permission settings, so check there too if something looks wrong."
}'

privacy_audit() {
  report="privacy-audit-$(date +%Y%m%d).txt"
  echo "Reading app permissions from the phone (can take up to a minute)..."
  ash pm list packages -3 -i \
    | awk '{ p = $1; sub(/^package:/, "", p); i = "null"
             if (match($0, /installer=[^ ]+/)) i = substr($0, RSTART + 10, RLENGTH - 10)
             print p, i }' >"$TMPD/apps"
  ash dumpsys package packages >"$TMPD/pkgdump"
  grep -q 'Package \[' "$TMPD/pkgdump" || ash dumpsys package >"$TMPD/pkgdump"
  awk '
    /^ *Package \[/ { s = index($0, "["); e = index($0, "]"); pkg = substr($0, s + 1, e - s - 1); next }
    pkg != "" && match($0, /android\.permission\.[A-Z_]+: granted=true/) {
      perm = substr($0, RSTART + 19); sub(/:.*/, "", perm); print pkg, perm
    }' "$TMPD/pkgdump" | sort -u >"$TMPD/grants"
  {
    ash settings get secure enabled_accessibility_services | comps_to_pkgs | sed 's/^/ACCESSIBILITY /'
    ash settings get secure enabled_notification_listeners | comps_to_pkgs | sed 's/^/NOTIFICATIONS /'
    ash dumpsys device_policy | grep -E '^ +[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+:$' | comps_to_pkgs | sed 's/^/DEVICE_ADMIN /'
    ash 'for p in $(pm list packages -3 | cut -d: -f2); do echo "$p $(appops get $p REQUEST_INSTALL_PACKAGES)"; done' \
      | grep 'REQUEST_INSTALL_PACKAGES: allow' | awk '{ print "INSTALL_APPS", $1 }'
  } | sort -u >"$TMPD/special"
  awk -v today="$(date +%Y-%m-%d)" "$AUDIT_AWK" "$TMPD/apps" "$TMPD/grants" "$TMPD/special" | tee "$report"
  echo
  echo "A copy of this report was saved to $(pwd)/$report"
}

# ---------- Option 12: unused app finder ----------
# Inputs: user (apps you installed), usage (dumpsys usagestats), disk (dumpsys diskstats),
#         bg (apps that work in the background: keyboard, accessibility, notification access).
# Output: "days|package|size_mb|note" for apps unused for at least `min` days; days=99999 means no use recorded.
#         note is "careful" (authenticator/banking/payment), "bg" (works in the background) or empty.
UNUSED_AWK='
function dnum(d,   y, m, dd) {
  y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
  if (m <= 2) { y--; m += 12 }
  return int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + dd
}
function list_of(line, out,   s) { s = line; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s); gsub(/"/, "", s); return split(s, out, ",") }
FILENAME == ARGV[1] { user[$1] = 1; next }
FILENAME == ARGV[2] {
  if (!match($0, /package=[^ ]+/)) next
  p = substr($0, RSTART + 8, RLENGTH - 8)
  if (!(p in user)) next
  s = $0
  while (match(s, /lastTime[A-Za-z]*="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
    d = substr(s, RSTART + RLENGTH - 10, 10)
    if (d >= "2000" && (!(p in last) || d > last[p])) last[p] = d
    s = substr(s, RSTART + RLENGTH)
  }
  # Recent events ("time=... type=ACTIVITY_RESUMED package=...") also count as use.
  if ($0 ~ /type=(ACTIVITY_RESUMED|MOVE_TO_FOREGROUND)/ && match($0, /(^|[ \t])time="[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
    d = substr($0, RSTART + RLENGTH - 10, 10)
    if (!(p in last) || d > last[p]) last[p] = d
  }
  next
}
FILENAME == ARGV[3] {
  if ($0 ~ /^ *Package Names:/) np = list_of($0, names)
  else if ($0 ~ /^ *App Sizes:/) list_of($0, asz)
  else if ($0 ~ /^ *App Data Sizes:/) list_of($0, dsz)
  else if ($0 ~ /^ *Cache Sizes:/) list_of($0, csz)
  next
}
{ bg[$1] = 1 }
END {
  for (i = 1; i <= np; i++) if (asz[i] != "") size[names[i]] = asz[i] + dsz[i] + csz[i]
  t = dnum(today)
  for (p in user) {
    days = (p in last) ? t - dnum(last[p]) : 99999
    if (days < min) continue
    note = (tolower(p) ~ /authenticat|authy|otp|bank|pay|upi|wallet|paisa|phonepe|bhim/) ? "careful" : (p in bg) ? "bg" : ""
    printf "%d|%s|%s|%s\n", days, p, (p in size) ? sprintf("%d", size[p] / 1048576) : "", note
  }
}'

unused_apps() {
  echo "Reading app usage from the phone..."
  ash pm list packages -3 | sed 's/^package://' | pkgs_only | sort -u >"$TMPD/user"
  ash dumpsys usagestats >"$TMPD/usage"
  ash dumpsys diskstats >"$TMPD/disk"
  {
    ash settings get secure default_input_method
    ash settings get secure enabled_accessibility_services
    ash settings get secure enabled_notification_listeners
  } | comps_to_pkgs | sort -u >"$TMPD/bg"
  awk -v today="$(ash date +%Y-%m-%d)" -v min=30 "$UNUSED_AWK" \
    "$TMPD/user" "$TMPD/usage" "$TMPD/disk" "$TMPD/bg" | sort -t '|' -k1,1nr -k2,2 >"$TMPD/unused"
  if [ ! -s "$TMPD/unused" ]; then
    echo "Every app you installed was used in the last 30 days. Nothing to clean up."
    return
  fi
  echo
  echo "Apps you have not opened for 30+ days (most forgotten first):"
  printf '   %-13s %-9s %s\n' "LAST USED" "SIZE" "APP"
  awk -F '|' '{
      when = ($1 >= 99999) ? "over a year" : $1 " days ago"
      size = ($3 == "") ? "?" : $3 " MB"
      note = ($4 == "careful") ? "   (careful: may hold login codes or money)" \
           : ($4 == "bg") ? "   (works in the background, e.g. keyboard or autofill: keep it if you recognise it)" : ""
      printf "   %-13s %-9s %s%s\n", when, size, $2, note
      if ($3 != "") total += $3
    }
    END {
      printf "\n   Space you could free by removing all of them: about %d MB\n", total
      print "   \"over a year\" also includes apps you installed but never opened."
    }' "$TMPD/unused"
  echo
  echo "   Careful: removing an app deletes its data. Never remove authenticator, banking or payment"
  echo "   apps without checking first. Anything else can be reinstalled from the Play Store."
  read -r -p "Uninstall some of these now? (you'll be asked about each one) [y/N] " a
  [[ $a =~ ^[Yy]$ ]] || return
  while IFS='|' read -r _ pkg _ _ <&3; do
    read -r -p "Uninstall $pkg? [y/N] " b
    if [[ $b =~ ^[Yy]$ ]]; then
      if ash pm uninstall "$pkg" | grep -q Success; then echo "  uninstalled"; else echo "  could not uninstall"; fi
    fi
  done 3<"$TMPD/unused"
}

# ---------- Option 13: battery health log ----------
# Print the value of "key: value" from dumpsys battery output on stdin.
bfield() { awk -F': *' -v k="$1" '$1 ~ "^ *" k "$" { print $2; exit }'; }
# Read a number from a sysfs file on the phone (empty if unreadable).
sysnum() { ash cat "$1" 2>/dev/null | grep -E '^[0-9]+$' | head -n 1; }
# sysfs reports capacity in micro-amp-hours on most phones, plain mAh on a few.
to_mah() { if [ "$1" -gt 100000 ]; then echo $(($1 / 1000)); else echo "$1"; fi; }

battery_log() {
  b=$(ash dumpsys battery)
  level=$(printf '%s\n' "$b" | bfield level)
  temp=$(printf '%s\n' "$b" | bfield temperature)
  volt=$(printf '%s\n' "$b" | bfield voltage)
  hcode=$(printf '%s\n' "$b" | bfield health)
  case "$hcode" in
    2) hword="Good" ;; 3) hword="Overheating" ;; 4) hword="Dead" ;; 5) hword="Over-voltage" ;;
    6) hword="Failure" ;; 7) hword="Too cold" ;; *) hword="Unknown" ;;
  esac
  temp_c=$(awk -v t="${temp:-0}" 'BEGIN { printf "%.1f", t / 10 }')

  # Capacity: prefer the battery chip's own numbers, fall back to Android's battery stats.
  learned=""
  design=""
  full=$(sysnum /sys/class/power_supply/battery/charge_full)
  full_design=$(sysnum /sys/class/power_supply/battery/charge_full_design)
  cycles=$(sysnum /sys/class/power_supply/battery/cycle_count)
  [ -n "$full" ] && learned=$(to_mah "$full")
  [ -n "$full_design" ] && design=$(to_mah "$full_design")
  if [ -z "$learned" ] || [ -z "$design" ]; then
    bs=$(ash "dumpsys batterystats | grep -i 'battery capacity'")
    [ -n "$design" ] || design=$(printf '%s\n' "$bs" | awk -F': *' '/Estimated battery capacity/ { v = $2 + 0; if (v > 0) { print v; exit } }')
    [ -n "$learned" ] || learned=$(printf '%s\n' "$bs" | awk -F': *' '/Last learned battery capacity/ { v = $2 + 0; if (v > 0) { print v; exit } }')
  fi
  pct=$(awk -v l="${learned:-0}" -v d="${design:-0}" 'BEGIN { if (l > 0 && d > 0) printf "%.1f", l * 100 / d }')

  [ -s "$BATLOG" ] || echo "date,level_pct,temp_c,voltage_mv,health,learned_mah,design_mah,health_pct,cycles" >"$BATLOG"
  echo "$(date '+%Y-%m-%d %H:%M'),$level,$temp_c,$volt,$hword,$learned,$design,$pct,$cycles" >>"$BATLOG"

  echo "== Battery right now =="
  echo "  Charge:        ${level:-?}%"
  echo "  Temperature:   $temp_c C"
  echo "  Voltage:       ${volt:-?} mV"
  echo "  Condition:     $hword"
  if [ -n "$pct" ]; then
    echo "  Capacity:      $learned mAh now, $design mAh when new  ->  $pct% health"
  else
    echo "  Capacity:      your phone does not report this over USB"
  fi
  [ -n "$cycles" ] && echo "  Charge cycles: $cycles"
  echo
  if [ -n "$pct" ]; then
    awk -v p="$pct" 'BEGIN {
      if (p >= 90)      print "  Verdict: excellent for a phone this age."
      else if (p >= 80) print "  Verdict: normal wear. Charging between 20% and 80% will slow it down."
      else              print "  Verdict: worn out. A new battery from a Xiaomi service centre is cheap and makes the phone last all day again."
    }'
  fi
  awk -v t="$temp_c" 'BEGIN { if (t > 40) print "  Warning: the battery is hot. Heat wears it out fastest, so avoid gaming or charging under a pillow or in the sun." }'
  echo "  (Capacity is the phone's own estimate and moves a little between readings; it is most accurate"
  echo "   right after a full charge. Run this about once a week to see the trend.)"
  echo
  echo "== History (last 10 records, saved in $BATLOG) =="
  printf '  %-17s %-6s %-7s %s\n' "DATE" "CHARGE" "TEMP" "HEALTH"
  awk -F, 'NR > 1' "$BATLOG" | tail -n 10 \
    | awk -F, '{ printf "  %-17s %-6s %-7s %s\n", $1, $2 "%", $3 "C", ($8 == "" ? "?" : $8 "%") }'
  awk -F, 'NR > 1 && $8 != "" { if (first == "") { first = $8; fd = $1 } last = $8; ld = $1; n++ }
    END {
      if (n >= 2) printf "\n  Trend: %s%% on %s -> %s%% on %s (%+.1f points)\n", first, substr(fd, 1, 10), last, substr(ld, 1, 10), last - first
      else print "\n  Run this again in a week or two to see how your battery changes over time."
    }' "$BATLOG"
}

while true; do
  cat <<'MENU'

==== Phone Pro ====
 1) Health report (battery, storage, Android/MIUI version)
 2) Make the phone feel faster (animations 0.5x)
 3) Restore normal animations
 4) Block ads system-wide (AdGuard Private DNS)
 5) Turn ad-blocking DNS off
 6) Show possible bloatware (read-only, nothing is removed)
 7) Back up photos, documents and downloads to this computer
 8) Mirror and control the phone from this computer (scrcpy)
 9) Redmi/MIUI clean-up: remove ads and junk apps (asks about each one)
10) Undo option 9: restore every app it removed
11) Privacy audit: which apps can read your SMS, contacts, location, mic, camera
12) Find apps you haven't used in 30+ days (and how much space they take)
13) Battery health log (saves a record each time, so you can see the trend)
 q) Quit
MENU
  read -r -p "Choose: " c || exit 0
  case "$c" in
    1) health ;;
    2) faster ;;
    3) reset_anim ;;
    4) adblock_dns ;;
    5) dns_off ;;
    6) list_apps ;;
    7) backup_media ;;
    8) mirror ;;
    9) redmi_debloat ;;
    10) restore_removed ;;
    11) privacy_audit ;;
    12) unused_apps ;;
    13) battery_log ;;
    q|Q) exit 0 ;;
    *) echo "Unknown option." ;;
  esac
done
