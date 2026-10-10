# ---------- Lost-or-stolen readiness check (stolen-ready) ----------
# Entry point: stolen_ready. Everything else is prefixed sr_.
# Read-only unless you answer y. Changes it can make (each asked first, each undoable):
#   screen timeout / lock delay, turning Location on, bringing back the Xiaomi Find device app.
# How each thing is read without root (Android 12 / MIUI 14, adb shell user):
#   screen lock   dumpsys lock_settings -> "CredentialType: None|Pattern|Pin|Password" (needs DUMP, shell has it).
#                 NOT "cmd lock_settings ...": its credential check counts as a wrong unlock attempt.
#   Smart Lock    dumpsys trust -> trustManaged= / managingTrust= (agents only listed when a lock exists)
#   Find My Dev.  dumpsys device_policy -> com.google.android.gms device admin
#   accounts      dumpsys account -> counted in memory only; names (emails) are never printed or saved
#   SIM PIN       dumpsys activity service TelephonyDebugService -> mPin1State= (best effort), else ask
#   IMEI          service call iphonesubinfo (best effort, strictly validated), else ask the user (*#06#)

SR_UNDO="$HOME/phone-pro-stolen-ready-undo.txt"   # old values of anything this option changed
SR_CARD="$HOME/phone-emergency-card.txt"          # the emergency card
SR_SETTINGS="-a android.settings.SETTINGS"        # last-resort page for every "open settings"

# ---- small helpers ----
sr_yes() {
  local a=""
  read -r -p "$1 [y/N] " a
  case "$a" in y|Y|yes|Yes|YES) return 0 ;; esac
  return 1
}
sr_isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# Milliseconds -> plain words.
sr_ms_words() {
  local ms=$1 s m
  if [ "$ms" -ge 86400000 ]; then echo "never (only when you press the power button)"
  elif [ "$ms" -le 0 ]; then echo "immediately"
  elif [ "$ms" -lt 60000 ] || [ $((ms % 60000)) -ne 0 ]; then
    s=$(((ms + 500) / 1000))
    if [ "$s" -eq 1 ]; then echo "1 second"; else echo "$s seconds"; fi
  else
    m=$((ms / 60000))
    if [ "$m" -eq 1 ]; then echo "1 minute"; else echo "$m minutes"; fi
  fi
}

# Print the result line of one check and remember it for the score.
# $1 = check number, $2 = PASS or FIX, $3 = what to fix (for the summary; empty for PASS).
sr_result() {
  sr_st[$1]=$2
  sr_fix[$1]=$3
  printf '   Result: %s\n' "$2"
}
sr_head() { printf '\n%s. %s\n' "$1" "$2"; }

# Run "am start <args>" on the phone. Returns 0 only if the phone says the page was started.
sr_am_ok() {
  local out
  out=$(ash "am start $1 2>&1")
  case "$out" in
    *Error*|*Exception*|*"unable to resolve"*|*"not found"*) return 1 ;;
    *Starting:*|*Warning:*) return 0 ;;
  esac
  return 1
}

# Open a settings page on the phone. $1 = what it is (for messages), then targets such as
# "-a android.settings.DISPLAY_SETTINGS". Falls back to the main Settings page.
sr_open() {
  local what=$1 t
  shift
  for t in "$@" "$SR_SETTINGS"; do
    sr_am_ok "$t" || continue
    if [ "$t" = "$SR_SETTINGS" ] && [ $# -gt 0 ]; then
      echo "   That page could not be opened directly, so the main Settings app is open instead."
    else
      echo "   Opened $what on the phone."
    fi
    echo "   Unlock the phone to see it."
    return 0
  done
  echo "   Could not open Settings on the phone. Please open it by hand."
  return 1
}
sr_offer_open() {
  local what=$1
  shift
  if sr_yes "   Open $what on the phone now?"; then sr_open "$what" "$@"; fi
}

# Change a system/secure setting and read it back (MIUI silently refuses without the Security settings toggle).
sr_put() {
  ash settings put "$1" "$2" "$3" >/dev/null 2>&1
  if [ "$(ash settings get "$1" "$2")" = "$3" ]; then return 0; fi
  echo "   The phone refused the change."
  echo "   Turn on 'USB debugging (Security settings)' in Developer options (needs a SIM and Mi account), then try again."
  return 1
}

# ---- undo file: one line per change, "kind|key|old value|label" ----
sr_undo_has() {
  [ -f "$SR_UNDO" ] || return 1
  awk -F'|' -v n="$1" -v k="$2" '$1 == n && $2 == k { f = 1 } END { exit f ? 0 : 1 }' "$SR_UNDO"
}
# Save the old value before a change. Keeps the first (original) value if it was already saved.
# Returns 0 if a new line was added, 1 if one was already there.
sr_undo_save() {
  sr_undo_has "$1" "$2" && return 1
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$SR_UNDO"
  return 0
}
# Remove a line again (used when a change did not happen).
sr_undo_drop() {
  [ -f "$SR_UNDO" ] || return 0
  awk -F'|' -v n="$1" -v k="$2" '!($1 == n && $2 == k)' "$SR_UNDO" >"$TMPD/sr_undo_tmp"
  if [ -s "$TMPD/sr_undo_tmp" ]; then cat "$TMPD/sr_undo_tmp" >"$SR_UNDO"; else rm -f "$SR_UNDO"; fi
}
sr_undo_word() {
  case "$1|$3" in
    location\|off) echo "off" ;;
    location\|on) echo "on" ;;
    app\|*) echo "not installed" ;;
    *\|null) echo "the phone's default" ;;
    *) if sr_isnum "$3"; then sr_ms_words "$3"; else echo "$3"; fi ;;
  esac
}

# Offer to put back everything listed in the undo file. Returns 0 if an undo was done.
sr_undo_offer() {
  local ns key old label ok
  [ -s "$SR_UNDO" ] || return 1
  echo "Last time, this check changed these settings on your phone:"
  while IFS='|' read -r ns key old label <&3; do
    [ -n "$ns" ] || continue
    echo "   - $label: was $(sr_undo_word "$ns" "$key" "$old")"
    [ "$ns" = app ] && echo "     (putting this back removes the Xiaomi Find device app again)"
  done 3<"$SR_UNDO"
  if ! sr_yes "Put them back the way they were?"; then
    echo "Keeping them. (You can undo them next time you run this check.)"
    return 1
  fi
  : >"$TMPD/sr_undo_left"
  while IFS='|' read -r ns key old label <&3; do
    [ -n "$ns" ] || continue
    ok=0
    case "$ns" in
      system|secure)
        if [ "$old" = "null" ]; then
          ash settings delete "$ns" "$key" >/dev/null 2>&1
          [ "$(ash settings get "$ns" "$key")" = "null" ] && ok=1
        else
          sr_put "$ns" "$key" "$old" >/dev/null && ok=1
        fi ;;
      location)
        if [ "$old" = "off" ]; then ash cmd location set-location-enabled false >/dev/null 2>&1; else ash cmd location set-location-enabled true >/dev/null 2>&1; fi
        [ "$(sr_location_state)" = "$old" ] && ok=1 ;;
      app)
        ash pm uninstall --user 0 "$key" | grep -q Success && ok=1 ;;
    esac
    if [ "$ok" = 1 ]; then
      echo "   Put back: $label: $(sr_undo_word "$ns" "$key" "$old")"
    else
      echo "   Could not put back: $label"
      printf '%s|%s|%s|%s\n' "$ns" "$key" "$old" "$label" >>"$TMPD/sr_undo_left"
    fi
  done 3<"$SR_UNDO"
  if [ -s "$TMPD/sr_undo_left" ]; then
    cat "$TMPD/sr_undo_left" >"$SR_UNDO"
    echo "Some settings could not be put back. Turn on 'USB debugging (Security settings)' and try again."
  else
    rm -f "$SR_UNDO"
    echo "Everything is back the way it was."
  fi
  return 0
}

# ---- parsers (stdin = phone output) ----
# dumpsys lock_settings -> pin | pattern | password | secure | none | unknown (user 0 only).
sr_lock_type() {
  awk '
    /^ *User [0-9]+ *$/ { u = $2; next }
    /^ *CredentialType:/ && (u == "" || u == "0") && ct == "" { ct = $2 }
    /^ *Quality:/ && (u == "" || u == "0") && q == "" { q = $2 }
    END {
      t = tolower(ct)
      if (t == "pin" || t == "3") print "pin"
      else if (t == "pattern" || t == "1") print "pattern"
      else if (t == "password" || t == "2" || t == "4") print "password"
      else if (t == "none" || t == "-1") print "none"
      else if (q ~ /^[0-9]+$/) { if (q + 0 >= 65536) print "secure"; else print "none" }
      else print "unknown"
    }'
}
# dumpsys trust -> "ok <trustManaged> <agents> <managing> <trusted>" for user 0, or "unknown".
sr_trust_state() {
  awk '
    /^Trust manager state:/ { ok = 1; next }
    /^ User / { cur = ($0 ~ /\(id=0,/); inag = 0
                if (cur && match($0, /trustManaged=[01]/)) tm = substr($0, RSTART + 13, 1)
                next }
    cur && /^ *Enabled agents:/ { inag = 1; next }
    cur && /^ *Events:/ { inag = 0; next }
    cur && inag && /^ *[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+ *$/ { n++; next }
    cur && inag && /managingTrust=1/ { m++ }
    cur && inag && /trusted=1/ { tr++ }
    END { if (ok) print "ok", tm + 0, n + 0, m + 0, tr + 0; else print "unknown" }'
}
# dumpsys device_policy -> active device admins of user 0 (one component per line), "?" if unreadable.
sr_parse_admins() {
  awk '
    /Enabled Device Admins \(User / { ok = 1; u = $0; sub(/.*\(User /, "", u); sub(/[^0-9].*/, "", u); next }
    /Device Policy Manager/ { ok = 1 }
    u == "0" && /^ +[A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+:$/ { c = $1; sub(/:$/, "", c); print c }
    END { if (!ok) print "?" }'
}
# dumpsys account -> "<google> <xiaomi>" account counts for the first user (the owner), or "? ?".
# Only the type is looked at; account names are never printed.
sr_acct_counts() {
  awk '
    /^User / { users++; inlist = 0; next }
    users <= 1 && /^ *Accounts: [0-9]+/ { seen = 1; inlist = 1; next }
    inlist && /^ *Account \{name=.*, type=/ {
      t = $0; sub(/.*, type=/, "", t); sub(/\}.*/, "", t)
      if (t == "com.google") g++
      else if (t == "com.xiaomi") x++
      next
    }
    inlist { inlist = 0 }
    END { if (seen) print g + 0, x + 0; else print "? ?" }'
}
# Telephony dump lines (mAppType= / mPin1State= / mIccLockEnabled=) -> on | off | mixed | unknown.
sr_sim_state() {
  awk '
    function close_app() { if (rel) { if (on1) on++; else if (off1) off++ } rel = 0; on1 = 0; off1 = 0 }
    /mAppType=/ { close_app(); t = $0; sub(/.*mAppType=/, "", t); sub(/[^A-Z_].*/, "", t)
                  rel = (t == "APPTYPE_SIM" || t == "APPTYPE_USIM" || t == "APPTYPE_RUIM" || t == "APPTYPE_CSIM"); next }
    rel && /mPin1State=PINSTATE_ENABLED/ { on1 = 1; next }
    rel && /mPin1State=PINSTATE_DISABLED/ { off1 = 1; next }
    rel && /mIccLockEnabled=true/ { on1 = 1; off1 = 0; next }
    END { close_app()
          if (on && !off) print "on"; else if (off && !on) print "off"; else if (on && off) print "mixed"; else print "unknown" }'
}
# "service call" output -> the 15-character string it carries, only if the call succeeded.
sr_parcel_str() {
  awk -v Q="'" '
    { s = $0
      while ((i = index(s, Q)) > 0) {
        rest = substr(s, i + 1); j = index(rest, Q)
        if (j == 0) break
        txt = txt substr(rest, 1, j - 1)
        s = substr(s, 1, i - 1) " " substr(rest, j + 1)
      }
      gsub(/Result: Parcel\(/, " ", s); gsub(/0x[0-9a-fA-F]+:/, " ", s); gsub(/\)/, " ", s)
      words = words " " s }
    END {
      n = split(words, w, " ")
      if (n < 2 || w[1] != "00000000" || w[2] != "0000000f") exit 1
      gsub(/[. ]/, "", txt)
      if (txt !~ /^[0-9]+$/ || length(txt) != 15) exit 1
      print txt }'
}
# A real IMEI is 15 digits and its last digit is a Luhn check digit.
sr_valid_imei() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -eq 15 ] || return 1
  printf '%s\n' "$1" | awk '{ s = 0; n = length($0)
    for (i = n; i >= 1; i--) { d = substr($0, i, 1) + 0; if ((n - i) % 2 == 1) { d = d * 2; if (d > 9) d = d - 9 } s += d }
    exit (s % 10 == 0) ? 0 : 1 }'
}
# Location on/off: secure location_mode first (0 = off), then "cmd location". Prints on | off | unknown.
sr_location_state() {
  local lm le
  lm=$(ash settings get secure location_mode)
  if sr_isnum "$lm"; then
    if [ "$lm" -eq 0 ]; then echo off; else echo on; fi
    return
  fi
  le=$(ash cmd location is-location-enabled)
  case "$le" in true) echo on ;; false) echo off ;; *) echo unknown ;; esac
}

# ---- the 8 checks ----
sr_check_lock() {
  local w how
  how="Settings > Passwords & security > Screen lock > PIN (6 digits or more)."
  sr_head 1 "Screen lock (PIN, pattern or password)"
  case "$sr_lock" in
    pin|pattern|password)
      [ "$sr_lock" = pin ] && w="a PIN" || w="a $sr_lock"
      echo "   You unlock with $w. A thief cannot get into your apps, photos or bank apps without it."
      [ "$sr_lock" = pattern ] && echo "   Tip: a 6-digit PIN is harder to guess than a pattern (patterns leave smudge marks)."
      sr_result 1 PASS "" ;;
    secure)
      echo "   A PIN, pattern or password is set."
      sr_result 1 PASS "" ;;
    none)
      echo "   There is no PIN, pattern or password (only swipe, or nothing)."
      echo "   Anyone who picks up the phone gets into everything, and can switch off Find My Device."
      echo "   How to fix: $how"
      echo "   (Fingerprint and face unlock always need a PIN or pattern behind them.)"
      sr_result 1 FIX "Set a screen lock: $how"
      sr_offer_open "the screen lock settings" "-a android.app.action.SET_NEW_PASSWORD" "-a android.settings.SECURITY_SETTINGS" ;;
    *)
      echo "   Could not read the screen lock type from the phone."
      if sr_yes "   Do you need a PIN, pattern or password to unlock your phone?"; then
        echo "   OK, you confirmed it."
        sr_result 1 PASS ""
      else
        echo "   How to fix: $how"
        sr_result 1 FIX "Set a screen lock: $how"
        sr_offer_open "the screen lock settings" "-a android.app.action.SET_NEW_PASSWORD" "-a android.settings.SECURITY_SETTINGS"
      fi ;;
  esac
}

# Make the screen turn off after 1 minute (and lock 5 seconds later). Saves old values first.
sr_fix_timeout() {
  local so=$1 la=$2 added ok=1
  if [ "$so" -gt 60000 ]; then
    sr_undo_save system screen_off_timeout "$so" "Screen turns off after"; added=$?
    if sr_put system screen_off_timeout 60000; then so=60000; else ok=0; [ "$added" = 0 ] && sr_undo_drop system screen_off_timeout; fi
  fi
  if [ "$ok" = 1 ] && sr_isnum "$la" && [ "$la" -gt 5000 ] && [ $((so + la)) -gt 65000 ]; then
    sr_undo_save secure lock_screen_lock_after_timeout "$la" "Lock after the screen turns off"; added=$?
    if sr_put secure lock_screen_lock_after_timeout 5000; then la=5000; else ok=0; [ "$added" = 0 ] && sr_undo_drop secure lock_screen_lock_after_timeout; fi
  fi
  [ "$ok" = 1 ] || return 1
  echo "   Done: the screen now turns off after $(sr_ms_words "$so") and locks soon after."
  echo "   To undo: run this check again and answer y when it offers to put things back."
  return 0
}

sr_check_timeout() {
  local so la la_eff total how
  sr_head 2 "Screen turns off and locks within about 1 minute"
  how="Settings > Always-on display & Lock screen > Sleep > 1 minute."
  so=$(ash settings get system screen_off_timeout)
  la=$(ash settings get secure lock_screen_lock_after_timeout)
  if ! sr_isnum "$so"; then
    echo "   Could not read how long the screen stays on."
    echo "   Check it by hand: $how"
    sr_result 2 FIX "Check the screen turns off after 1 minute or less: $how"
    sr_offer_open "the display settings" "-a android.settings.DISPLAY_SETTINGS"
    return
  fi
  if sr_isnum "$la"; then la_eff=$la; else la_eff=5000; fi
  total=$((so + la_eff))
  if [ "$total" -le 65000 ]; then
    echo "   The screen turns off after $(sr_ms_words "$so") of no use, then locks."
    [ "$sr_lock" = none ] && echo "   (This only protects you once you have a screen lock: see check 1.)"
    sr_result 2 PASS ""
    return
  fi
  if [ "$so" -gt 60000 ]; then
    echo "   The screen stays on for $(sr_ms_words "$so") when you stop using it."
  else
    echo "   The screen turns off after $(sr_ms_words "$so"), but the lock only starts $(sr_ms_words "$la_eff") later."
  fi
  echo "   If someone grabs the phone while it's unlocked, they have all that time to get in."
  echo "   How to fix: $how (or search \"Sleep\" in Settings)"
  if sr_yes "   Change it now so the screen turns off after 1 minute?"; then
    if sr_fix_timeout "$so" "$la"; then sr_result 2 PASS ""; return; fi
  fi
  sr_result 2 FIX "Make the screen turn off after 1 minute: $how"
  sr_offer_open "the display settings" "-a android.settings.DISPLAY_SETTINGS"
}

sr_check_smartlock() {
  local how ok tm n m tr
  sr_head 3 "Smart Lock is not keeping the phone unlocked"
  how="Settings > Passwords & security > Smart Lock (or search \"Smart Lock\" in Settings)."
  set -- $(ash dumpsys trust | sr_trust_state)
  ok=${1:-unknown}; tm=${2:-0}; n=${3:-0}; m=${4:-0}; tr=${5:-0}
  if [ "$ok" != ok ]; then
    echo "   Could not read the Smart Lock state from the phone."
    echo "   Check it by hand: $how"
    sr_result 3 FIX "Check Smart Lock is off: $how"
    sr_offer_open "the security settings" "-a android.settings.SECURITY_SETTINGS"
    return
  fi
  if [ "$tm" = 1 ] || [ "$m" -gt 0 ] || [ "$tr" -gt 0 ]; then
    echo "   Smart Lock is set up, so the phone can stay unlocked by itself: in your pocket"
    echo "   (On-body detection), at a trusted place, or near a trusted Bluetooth watch or car."
    echo "   A thief who walks off with it may find it unlocked."
    echo "   How to fix: $how"
    echo "   Then turn off On-body detection and remove trusted places and trusted devices."
    sr_result 3 FIX "Turn off Smart Lock: $how"
    sr_offer_open "the security settings" "-a android.settings.SECURITY_SETTINGS"
  elif [ "$n" -gt 0 ]; then
    echo "   Smart Lock is available but nothing is set up to keep the phone unlocked."
    sr_result 3 PASS ""
  else
    echo "   Smart Lock is not in use."
    [ "$sr_lock" = none ] && echo "   (It only works once a screen lock is set, so check again after fixing check 1.)"
    sr_result 3 PASS ""
  fi
}

sr_check_fmd() {
  local how
  sr_head 4 "Google Find My Device is on"
  how="Settings > Google > Find My Device > turn on \"Use Find My Device\"."
  if ! printf '%s\n' "$sr_pkgs" | grep -qx com.google.android.gms; then
    if [ -n "$sr_pkgs" ]; then
      echo "   Google Play services is not on this phone, so Google Find My Device cannot work."
      echo "   Xiaomi Find device (check 5) is your way to find it."
      sr_result 4 FIX "Google Find My Device cannot work without Google Play services: rely on Xiaomi Find device."
      return
    fi
    echo "   Could not read the list of apps from the phone."
  fi
  if printf '%s\n' "$sr_admins" | grep -q '^com\.google\.android\.gms/'; then
    echo "   Find My Device is on: Google Play services can ring, lock and erase the phone from"
    echo "   android.com/find (it is registered as a 'device admin', which is what allows that)."
    sr_result 4 PASS ""
    return
  fi
  if [ "$sr_admins" = "?" ]; then
    echo "   Could not read the phone's device admin list."
  else
    echo "   Could not confirm it from the phone's data (newer Google Play services do not always show up there)."
  fi
  echo "   On the phone, look at: Settings > Google > Find My Device."
  if sr_yes "   Is \"Use Find My Device\" switched on? (not sure? answer N)"; then
    echo "   OK, you confirmed it."
    sr_result 4 PASS ""
    return
  fi
  echo "   Without it you cannot ring, lock or erase the phone from android.com/find."
  echo "   How to fix: $how"
  echo "   (Newer phones may call it Find Hub. It also needs Location and a Google account.)"
  sr_result 4 FIX "Turn on Google Find My Device: $how"
  sr_offer_open "Google settings" "-n com.google.android.gms/.app.settings.GoogleSettingsLink" "-a android.settings.SECURITY_SETTINGS"
}

sr_check_xiaomi() {
  local how pkg=com.xiaomi.finddevice mf out added
  sr_head 5 "Xiaomi Find device is ready"
  how="Settings > Xiaomi account > Xiaomi Cloud > Find device > turn on."
  mf=$(ash getprop ro.product.manufacturer | tr 'A-Z' 'a-z')
  if [ -z "$sr_pkgs" ]; then
    echo "   Could not read the list of apps from the phone."
    echo "   Check it by hand: $how"
    sr_result 5 FIX "Check Xiaomi Find device is on: $how"
    sr_offer_open "the accounts settings" "-a android.settings.SYNC_SETTINGS"
    return
  fi
  if ! printf '%s\n' "$sr_pkgs" | grep -qx "$pkg"; then
    case "$mf" in
      *xiaomi*|*redmi*|*poco*) ;;
      *) echo "   Not a Xiaomi phone, so there is nothing to set up here."
         sr_result 5 PASS ""
         return ;;
    esac
    echo "   The Xiaomi Find device app is missing (maybe removed by a clean-up tool)."
    echo "   Without it, i.mi.com cannot find, lock or erase this phone."
    if sr_yes "   Bring the Xiaomi Find device app back now? (it is still stored on the phone)"; then
      sr_undo_save app "$pkg" removed "Xiaomi Find device app"; added=$?
      out=$(ash cmd package install-existing "$pkg")
      if printf '%s\n' "$out" | grep -q installed && ash pm list packages | sed 's/^package://' | grep -qx "$pkg"; then
        echo "   Done: the Xiaomi Find device app is back. Now switch it on: $how"
        echo "   To undo: run this check again and answer y when it offers to put things back."
        sr_result 5 FIX "Switch on Xiaomi Find device: $how"
        sr_offer_open "the accounts settings" "-a android.settings.SYNC_SETTINGS"
        return
      fi
      [ "$added" = 0 ] && sr_undo_drop app "$pkg"
      echo "   Could not bring it back: it is not stored on this phone any more."
    fi
    sr_result 5 FIX "Bring back the Xiaomi Find device app (it was removed), then: $how"
    return
  fi
  if printf '%s\n' "$sr_disabled" | grep -qx "$pkg"; then
    echo "   The Xiaomi Find device app is disabled, so it cannot find, lock or erase the phone."
    echo "   How to fix: Settings > Apps > Manage apps > Find device > Enable."
    sr_result 5 FIX "Enable the Xiaomi Find device app: Settings > Apps > Manage apps > Find device > Enable."
    sr_offer_open "the Find device app page" "-a android.settings.APPLICATION_DETAILS_SETTINGS -d package:$pkg"
    return
  fi
  if [ "$sr_xa" = "?" ]; then
    echo "   The Xiaomi Find device app is there, but the phone's account list could not be read."
    echo "   Check it by hand: $how"
    sr_result 5 FIX "Check Xiaomi Find device is on: $how"
    sr_offer_open "the accounts settings" "-a android.settings.SYNC_SETTINGS"
  elif [ "$sr_xa" -gt 0 ]; then
    echo "   The Xiaomi Find device app is ready and you are signed in to a Xiaomi account,"
    echo "   so i.mi.com can find, ring, lock or erase the phone."
    echo "   (To be sure the switch is on: $how)"
    sr_result 5 PASS ""
  else
    echo "   You are not signed in to a Xiaomi account, so Xiaomi Find device cannot work."
    echo "   It is a second, independent way to find the phone (at i.mi.com)."
    echo "   How to fix: $how"
    sr_result 5 FIX "Sign in to a Xiaomi account and turn on Find device: $how"
    sr_offer_open "the accounts settings" "-a android.settings.SYNC_SETTINGS"
  fi
}

sr_check_location() {
  local st added
  sr_head 6 "Location is on"
  st=$(sr_location_state)
  case "$st" in
    on)
      echo "   Location is on, so Find My Device can show you where the phone is."
      sr_result 6 PASS "" ;;
    off)
      echo "   Location is off. Find My Device can still ring, lock or erase the phone,"
      echo "   but it cannot show you where it is."
      echo "   How to fix: swipe down from the top and tap Location (or Settings > Location)."
      if sr_yes "   Turn Location on now?"; then
        sr_undo_save location enabled off "Location"; added=$?
        ash cmd location set-location-enabled true >/dev/null 2>&1
        if [ "$(sr_location_state)" = on ]; then
          echo "   Done: Location is on. It uses very little battery by itself."
          echo "   To undo: run this check again and answer y when it offers to put things back."
          sr_result 6 PASS ""
          return
        fi
        [ "$added" = 0 ] && sr_undo_drop location enabled
        echo "   The phone refused the change."
        echo "   Turn on 'USB debugging (Security settings)' in Developer options, then try again."
      fi
      sr_result 6 FIX "Turn on Location: swipe down from the top and tap Location."
      sr_offer_open "the location settings" "-a android.settings.LOCATION_SOURCE_SETTINGS" ;;
    *)
      echo "   Could not read whether Location is on."
      echo "   Check it by hand: swipe down from the top and look at the Location tile."
      sr_result 6 FIX "Check Location is on: swipe down from the top and look at the Location tile."
      sr_offer_open "the location settings" "-a android.settings.LOCATION_SOURCE_SETTINGS" ;;
  esac
}

sr_check_google() {
  local how
  sr_head 7 "A Google account is signed in"
  how="Settings > Accounts & sync > Add account > Google."
  if [ "$sr_ga" = "?" ]; then
    echo "   Could not read the phone's account list."
    echo "   Check it by hand: Settings > Accounts & sync."
    sr_result 7 FIX "Check a Google account is signed in: Settings > Accounts & sync."
    sr_offer_open "the accounts settings" "-a android.settings.SYNC_SETTINGS"
  elif [ "$sr_ga" -gt 0 ]; then
    if [ "$sr_ga" = 1 ]; then echo "   1 Google account is signed in."; else echo "   $sr_ga Google accounts are signed in."; fi
    echo "   That is the account you sign in with at android.com/find. Make sure you know its password."
    sr_result 7 PASS ""
  else
    echo "   No Google account is signed in, so Google Find My Device cannot work"
    echo "   and your contacts and photos are not backed up to Google."
    echo "   How to fix: $how"
    sr_result 7 FIX "Sign in to a Google account: $how"
    sr_offer_open "the add-account page" "-a android.settings.ADD_ACCOUNT_SETTINGS" "-a android.settings.SYNC_SETTINGS"
  fi
}

sr_check_sim() {
  local st how
  sr_head 8 "SIM card PIN"
  how="Settings > Passwords & security > Privacy > SIM card lock."
  echo "   Checking the SIM card (a few seconds)..."
  st=$(ash "dumpsys activity service TelephonyDebugService | grep -E 'mAppType=|mPin1State=|mIccLockEnabled='" | sr_sim_state)
  case "$st" in
    on)
      echo "   Your SIM asks for a PIN after a restart (read from the phone)."
      echo "   A thief cannot use it in another phone to receive your calls and OTP codes."
      sr_result 8 PASS ""
      return ;;
    off) echo "   Your SIM does not ask for a PIN after a restart (read from the phone)." ;;
    mixed) echo "   One of your SIM cards asks for a PIN after a restart, the other does not (read from the phone)." ;;
    *)
      echo "   The phone does not share this setting over USB, so please answer this yourself."
      if sr_yes "   Does your SIM ask for a PIN after the phone restarts?"; then
        echo "   OK, you confirmed it."
        sr_result 8 PASS ""
        return
      fi ;;
  esac
  echo "   Without a SIM PIN, a thief can put your SIM in another phone and receive your calls"
  echo "   and SMS, including OTP codes for bank, UPI and WhatsApp."
  echo "   How to fix: $how (or search \"SIM lock\" in Settings)"
  echo "   You need the SIM's current PIN: ask your mobile operator if you don't know it."
  echo "   Careful: 3 wrong tries block the SIM until you enter the PUK code (your operator can give it)."
  echo "   Write the new PIN down somewhere safe."
  sr_result 8 FIX "Add a SIM PIN: $how"
  sr_offer_open "the security settings" "-a android.settings.SECURITY_SETTINGS"
}

# ---- emergency card ----
# Ask for one IMEI. Sets sr_ans (empty if skipped).
sr_ask_imei() {
  local tries=0 x
  sr_ans=""
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    x=""
    read -r -p "   Type $1 (15 digits), or just press Enter to skip: " x
    x=${x%%/*}
    x=$(printf '%s' "$x" | tr -d ' \t\r-')
    [ -n "$x" ] || return 1
    if sr_valid_imei "$x"; then sr_ans=$x; return 0; fi
    echo "   That doesn't look like an IMEI: it must be 15 digits, typed exactly as shown. Try again."
  done
  echo "   Skipped. You can add it next time you run this check."
  return 1
}

sr_card() {
  local mf model market rel miui inc serial multi ops i1 i2 c src when imei2_note gline xline f
  echo
  echo "== Emergency card =="
  echo "Reading the phone's details..."
  mf=$(ash getprop ro.product.manufacturer)
  model=$(ash getprop ro.product.model)
  market=$(ash getprop ro.product.marketname)
  rel=$(ash getprop ro.build.version.release)
  miui=$(ash getprop ro.miui.ui.version.name)
  inc=$(ash getprop ro.build.version.incremental)
  serial=$(ash getprop ro.serialno)
  case "$serial" in ''|unknown) serial=$(adb get-serialno </dev/null 2>/dev/null | tr -d '\r') ;; esac
  case "$serial" in ''|unknown) serial="unknown (see Settings > About phone > Detailed info and specs)" ;; esac
  multi=$(ash getprop persist.radio.multisim.config)
  ops=$(ash getprop gsm.sim.operator.alpha | sed 's/,,*/, /g; s/^, //; s/, $//')

  # IMEI: from the phone if it allows it (strictly checked), else from the last card, else typed in.
  i1=$(ash service call iphonesubinfo 1 s16 com.android.shell | sr_parcel_str)
  sr_valid_imei "$i1" || i1=""
  i2=""
  src="read from the phone"
  if [ -n "$i1" ]; then
    # Only trust the per-slot call if it gives the same IMEI 1 back for slot 0.
    if [ "$(ash service call iphonesubinfo 4 i32 0 s16 com.android.shell | sr_parcel_str)" = "$i1" ]; then
      i2=$(ash service call iphonesubinfo 4 i32 1 s16 com.android.shell | sr_parcel_str)
      { sr_valid_imei "$i2" && [ "$i2" != "$i1" ]; } || i2=""
    fi
    echo "   IMEI read from the phone: $i1${i2:+ and $i2}"
  else
    if [ -f "$SR_CARD" ]; then
      c=$(sed -n 's/^IMEI 1: *\([0-9][0-9]*\).*/\1/p' "$SR_CARD" | head -n 1)
      sr_valid_imei "$c" && i1=$c
      c=$(sed -n 's/^IMEI 2: *\([0-9][0-9]*\).*/\1/p' "$SR_CARD" | head -n 1)
      sr_valid_imei "$c" && i2=$c
    fi
    if [ -n "$i1" ]; then
      src="typed in earlier"
      echo "   Using the IMEI you typed in last time: $i1${i2:+ and $i2}"
    else
      src="typed in"
      echo "   The phone does not share its IMEI over USB. The IMEI is the number police and the"
      echo "   CEIR portal use to block a stolen phone. Dial *#06# on the phone to see it."
      if sr_yes "   Open the phone's dialer with *#06# typed in?"; then
        if sr_am_ok "-a android.intent.action.DIAL -d 'tel:*%2306%23'"; then
          echo "   Opened the dialer. If the IMEI does not appear by itself, press the call button."
        else
          echo "   Could not open the dialer. Open the Phone app and dial *#06#."
        fi
      fi
      if sr_ask_imei "IMEI 1"; then
        i1=$sr_ans
        case "$multi" in
          ss|"") ;;
          *) if sr_ask_imei "IMEI 2 (dual-SIM phones have two)"; then [ "$sr_ans" != "$i1" ] && i2=$sr_ans; fi ;;
        esac
      fi
    fi
  fi
  if [ -z "$i2" ]; then
    case "$multi" in ss) imei2_note="(single-SIM phone: none)" ;; *) imei2_note="not recorded (dial *#06# on the phone to see it)" ;; esac
  fi

  case "$sr_ga" in ''|"?") gline="could not be read" ;; 0) gline="none signed in" ;; *) gline="$sr_ga signed in (use it at android.com/find)" ;; esac
  case "$sr_xa" in ''|"?") xline="could not be read" ;; 0) xline="not signed in" ;; *) xline="signed in (use it at i.mi.com)" ;; esac
  when=$(date '+%Y-%m-%d')
  f="$TMPD/sr_card"
  {
    echo "=================================================================="
    echo " PHONE EMERGENCY CARD  -  keep a copy OFF the phone"
    echo "=================================================================="
    echo "Made on $when by phone-pro. Print it, or email it to yourself, so you"
    echo "have it on the day the phone is gone. Keep it private: it holds the"
    echo "phone's serial number and IMEI."
    echo
    echo "Phone:          ${mf:-?} ${model:-?}${market:+ ($market)}"
    echo "Software:       Android ${rel:-?}${miui:+, MIUI $miui ($inc)}"
    echo "Serial number:  $serial"
    if [ -n "$i1" ]; then echo "IMEI 1:         $i1   ($src)"; else echo "IMEI 1:         not recorded (dial *#06# on the phone to see it)"; fi
    if [ -n "$i2" ]; then echo "IMEI 2:         $i2   ($src)"; else echo "IMEI 2:         $imei2_note"; fi
    echo "SIM operator:   ${ops:-unknown}"
    echo "Google account: $gline"
    echo "Xiaomi account: $xline"
    echo
    echo "IF THE PHONE IS LOST OR STOLEN - do these in order, from a computer"
    echo "or a friend's phone:"
    echo
    echo "1. Google: go to android.com/find and sign in with the Google account"
    echo "   that is on the phone."
    echo "   - Play sound: rings at full volume for 5 minutes, even on silent."
    echo "   - Secure device: locks it and shows a message and a number to call."
    echo "   - Erase device: wipes everything. Only when you are sure it is gone:"
    echo "     after erasing you can no longer see where it is."
    echo "2. Xiaomi: go to i.mi.com, sign in with your Xiaomi account, open"
    echo "   \"Find device\": map, ring, lost mode (lock) or erase."
    echo "3. Call your mobile operator (${ops:-the company that gave you the SIM}) and ask them to BLOCK"
    echo "   the SIM, then get a replacement SIM with the same number (take ID proof)."
    echo "   This stops OTP codes reaching the thief, and you need the number"
    echo "   working again for step 5."
    echo "4. Report it to the police (online or at the police station). Keep the"
    echo "   complaint number and a copy: CEIR and insurance ask for it."
    echo "5. India: block the IMEI on the government CEIR portal: ceir.gov.in"
    echo "   (also reachable from sancharsaathi.gov.in). The phone then cannot be"
    echo "   used on any Indian network. You need: the IMEI(s) above, brand and model,"
    echo "   the police complaint number and copy, ID proof, and a working number"
    echo "   for the OTP. If you get the phone back, unblock it on the same site."
    echo "6. Change passwords from another device: your Google account first"
    echo "   (myaccount.google.com), then your Xiaomi account, email, and bank/UPI"
    echo "   apps. Call your bank's helpline to block UPI and mobile banking on the"
    echo "   lost phone. If money was taken, call 1930 or use cybercrime.gov.in."
    echo "7. Sign the lost phone out of your Google account: myaccount.google.com >"
    echo "   Security > Your devices > (the phone) > Sign out."
    echo
    echo "TIP: if your Google account sends sign-in codes to this phone, you can be"
    echo "locked out when it is gone. Save backup codes now: myaccount.google.com >"
    echo "Security > 2-Step Verification > Backup codes."
  } >"$f"
  if (umask 077; cat "$f" >"$SR_CARD") 2>/dev/null; then
    echo "   Phone: ${mf:-?} ${model:-?}, serial $serial"
    if [ -n "$i1" ]; then echo "   IMEI:  $i1${i2:+, $i2}"; else echo "   IMEI:  not recorded"; fi
    echo "   Saved your emergency card, with a step-by-step plan for the day the phone is lost, to:"
    echo "   $SR_CARD"
    echo "   Print it or email it to yourself: it is no use if it is only on the phone."
  else
    echo "   Could not save the emergency card to $SR_CARD."
  fi
}

# ---- score ----
sr_summary() {
  local i n=0 grade
  for i in 1 2 3 4 5 6 7 8; do [ "${sr_st[$i]}" = PASS ] && n=$((n + 1)); done
  if [ "$n" -eq 8 ]; then grade="excellent: your phone is as ready as it can be."
  elif [ "$n" -ge 6 ]; then grade="good, with a few gaps."
  elif [ "$n" -ge 3 ]; then grade="some important gaps."
  else grade="at risk: a thief would have an easy time."
  fi
  echo
  echo "== Your lost-or-stolen score: $n out of 8 ($grade) =="
  for i in 1 2 3 4 5 6 7 8; do printf '   %s  %s\n' "${sr_st[$i]}" "${sr_title[$i]}"; done
  [ "$n" -eq 8 ] && { echo "   Run this again every few months, and after any phone update."; return; }
  echo
  echo "Fix these, most important first:"
  n=0
  # Screen lock first (nothing else matters without it), then what makes finding the phone possible.
  for i in 1 7 4 6 2 3 5 8; do
    [ "${sr_st[$i]}" = PASS ] && continue
    n=$((n + 1))
    printf '   %d) %s\n' "$n" "${sr_fix[$i]}"
  done
  echo "Run this check again after fixing things to see your new score."
}

stolen_ready() {
  local i out
  echo "== Lost-or-stolen readiness check =="
  echo "Checks 8 things that decide whether you can find, lock or wipe your phone if it is"
  echo "lost or stolen, then saves an emergency card on this computer."
  echo "Nothing on the phone changes unless you answer y. Just pressing Enter means No."
  echo
  if sr_undo_offer; then
    echo "Run this option again for a fresh check."
    return 0
  fi
  sr_title[1]="Screen lock";             sr_title[2]="Screen turns off and locks quickly"
  sr_title[3]="Smart Lock not keeping it unlocked"; sr_title[4]="Google Find My Device"
  sr_title[5]="Xiaomi Find device";      sr_title[6]="Location"
  sr_title[7]="Google account";          sr_title[8]="SIM card PIN"
  for i in 1 2 3 4 5 6 7 8; do sr_st[$i]=FIX; sr_fix[$i]=""; done
  echo "Reading the phone's security settings (takes a few seconds)..."
  sr_lock=$(ash dumpsys lock_settings | sr_lock_type)
  sr_pkgs=$(ash pm list packages | sed 's/^package://' | pkgs_only)
  sr_disabled=$(ash pm list packages -d | sed 's/^package://' | pkgs_only)
  sr_admins=$(ash dumpsys device_policy | sr_parse_admins)
  out=$(ash dumpsys account | sr_acct_counts)   # counts only: account names never leave awk
  sr_ga=${out%% *}; sr_xa=${out##* }
  sr_check_lock
  sr_check_timeout
  sr_check_smartlock
  sr_check_fmd
  sr_check_xiaomi
  sr_check_location
  sr_check_google
  sr_check_sim
  sr_card
  sr_summary
}
