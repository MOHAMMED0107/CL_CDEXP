# ---------- Battery drain detective ----------
# Read-only report of what drained the battery since the last full charge, saved to
# battery-drain-YYYYMMDD.txt in the current folder, plus optional fixes for three hidden drains.
# Entry point: battery_drain. Everything else here starts with bd_ / BD_.
#
# Data sources (all work as the adb shell user, no root):
#   dumpsys batterystats --charged   needs android.permission.DUMP + usage-stats app-op (shell has both)
#   pm list packages -U -u / -3       maps UIDs (u0a170 = 10170) to package names, marks apps you installed
#   settings get/put/delete global    needs WRITE_SECURE_SETTINGS (shell has it; MIUI also wants
#                                     "USB debugging (Security settings)", which setg checks)
#   cmd wifi status                   non-privileged; shows whether Wi-Fi scanning is really on
# Android 12 format (AOSP BatteryUsageStats.dump / UidBatteryConsumer.dump):
#     Estimated power use (mAh):
#       Capacity: 5020, Computed drain: 1698, actual drain: 1690-1740
#       Global
#         screen: 466 apps: 466 duration: 4h 21m 7s 330ms
#       UID u0a233: 345 ( screen=98.4 cpu=142 mobile_radio=61.2 ... )
# Android 13+ adds " fg: 1.2 bg: 3.4 fgs: 0.5" after the total; Android 11 used "Uid ...".
# Partial wake lock times (lines "  Wake lock u0a233 NAME: 18m 2s 117ms (212 times) ...") only
# count while on battery with the screen off.

BD_UNDO_NAME="phone-pro-battery-undo.txt"

# key|name shown to the user|what it does|what turning it off changes
BD_SETTINGS=(
  "wifi_scan_always_enabled|Wi-Fi scanning|Lets apps and Google look for Wi-Fi networks to work out where you are, even when Wi-Fi is switched off.|Location may be a little less exact indoors while Wi-Fi is off. Calls, SMS and notifications are not affected."
  "ble_scan_always_enabled|Bluetooth scanning|Lets apps look for nearby Bluetooth gadgets (watches, shop beacons) even when Bluetooth is switched off.|Finding nearby gadgets only works while Bluetooth is on. Calls, SMS and notifications are not affected."
  "mobile_data_always_on|Mobile data always active|A developer option that keeps mobile data connected even while you use Wi-Fi, so switching over is a little faster.|When Wi-Fi drops, mobile data may take a few seconds longer to take over. Calls and SMS are not affected."
)

# Friendly names for common apps (package|name). Anything else is shown by its package name.
BD_APP_NAMES=(
  "com.whatsapp|WhatsApp"
  "com.whatsapp.w4b|WhatsApp Business"
  "com.instagram.android|Instagram"
  "com.facebook.katana|Facebook"
  "com.facebook.orca|Messenger"
  "com.facebook.lite|Facebook Lite"
  "com.snapchat.android|Snapchat"
  "com.zhiliaoapp.musically|TikTok"
  "com.twitter.android|X (Twitter)"
  "org.telegram.messenger|Telegram"
  "com.truecaller|Truecaller"
  "com.spotify.music|Spotify"
  "com.netflix.mediaclient|Netflix"
  "com.amazon.mShop.android.shopping|Amazon"
  "com.phonepe.app|PhonePe"
  "net.one97.paytm|Paytm"
  "com.google.android.apps.nbu.paisa.user|Google Pay"
  "in.org.npci.upiapp|BHIM"
  "com.google.android.gms|Google Play services"
  "com.google.android.googlequicksearchbox|Google app"
  "com.google.android.youtube|YouTube"
  "com.google.android.apps.youtube.music|YouTube Music"
  "com.android.chrome|Chrome"
  "com.google.android.apps.maps|Google Maps"
  "com.google.android.gm|Gmail"
  "com.google.android.apps.photos|Google Photos"
  "com.google.android.dialer|Phone (Google)"
  "com.google.android.apps.messaging|Messages (Google)"
  "com.android.vending|Play Store"
  "com.android.systemui|Status bar and notifications (System UI)"
  "com.android.phone|Phone and SIM service"
  "com.miui.home|MIUI home screen"
  "com.miui.securitycenter|MIUI Security"
  "com.miui.powerkeeper|MIUI battery manager"
  "com.miui.gallery|Gallery"
  "com.miui.weather2|Weather"
  "com.miui.analytics|Xiaomi usage tracking"
  "com.miui.msa.global|MIUI System Ads"
  "com.xiaomi.mipicks|GetApps"
  "com.mi.android.globalminusscreen|App Vault"
  "com.android.camera|Camera"
)

BD_AWK='
function num(s) {
  if (s ~ /^-?[0-9]+,[0-9]+$/) sub(/,/, ".", s)
  return s + 0
}
# "1d 2h 3m 4s 5ms", "2h3m4s5ms" or "401ms" -> milliseconds
function dur_ms(s,   t, u, v, tot) {
  tot = 0
  while (match(s, /[0-9]+(ms|d|h|m|s)/)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    if (t ~ /ms$/) { tot += substr(t, 1, length(t) - 2) + 0; continue }
    u = substr(t, length(t), 1); v = substr(t, 1, length(t) - 1) + 0
    if (u == "d") tot += v * 86400000
    else if (u == "h") tot += v * 3600000
    else if (u == "m") tot += v * 60000
    else tot += v * 1000
  }
  return tot
}
function upto_paren(s) { sub(/\(.*$/, "", s); return s }
function fmt_dur(ms,   d, h, m) {
  if (ms < 60000) return int(ms / 1000) " s"
  m = int(ms / 60000); h = int(m / 60); m = m % 60; d = int(h / 24); h = h % 24
  if (d > 0) return d (d == 1 ? " day " : " days ") h " h " m " min"
  if (h > 0) return h " h " m " min"
  return m " min"
}
function fmt_mah(x) { return (x >= 10) ? sprintf("%d", x + 0.5) : sprintf("%.1f", x) }
function fmt_pct(x) { return (x == int(x)) ? sprintf("%d", x) : sprintf("%.1f", x) }
# "1000" -> 1000, "u0a170" -> 10170, "u10a5" -> 1010005, "u0i3" -> 99003, "u0ai3" -> 90003, "u10s1000" -> 1001000
function uid_num(tok,   rest, u, a) {
  if (tok ~ /^[0-9]+$/) return tok + 0
  if (tok !~ /^u[0-9]+(a|i|ai|s)[0-9]+$/) return -1
  rest = substr(tok, 2); match(rest, /^[0-9]+/)
  u = substr(rest, 1, RLENGTH) + 0; rest = substr(rest, RLENGTH + 1)
  if (rest ~ /^ai/) a = 90000 + substr(rest, 3)
  else if (rest ~ /^a/) a = 10000 + substr(rest, 2)
  else if (rest ~ /^i/) a = 99000 + substr(rest, 2)
  else a = substr(rest, 2) + 0
  return u * 100000 + a
}
function sys_name(u) {
  if (u == 0) return "Android core (kernel)"
  if (u == 1000) return "Android system"
  if (u == 1001) return "Phone and mobile network service"
  if (u == 1002) return "Bluetooth service"
  if (u == 1010) return "Wi-Fi service"
  if (u == 1013) return "Media service (sound and video)"
  if (u == 1021) return "GPS service"
  if (u == 1027) return "NFC (tap to pay) service"
  if (u == 1036) return "System log service"
  if (u == 1041) return "Audio service"
  if (u == 1046) return "Video and audio decoder"
  if (u == 1047) return "Camera service"
  if (u == 1066) return "Android statistics service"
  if (u == 1068) return "Secure chip service (payments, SIM)"
  if (u == 1073) return "Network service"
  if (u == 2000) return "USB debugging (this tool)"
  if (u == 9999) return "Other system process"
  return "Android system process (ID " u ")"
}
function reason_of(c) {
  if (c == "screen") return "screen (while you were using it)"
  if (c == "cpu") return "processor (CPU)"
  if (c == "mobile_radio" || c == "radio") return "mobile data"
  if (c == "wifi") return "Wi-Fi"
  if (c == "gnss" || c == "gps") return "GPS location"
  if (c == "wakelock" || c == "wake") return "keeping the phone awake"
  if (c == "sensors" || c == "sensor") return "sensors (motion, steps)"
  if (c == "bluetooth" || c == "bt") return "Bluetooth"
  if (c == "camera") return "camera"
  if (c == "audio") return "playing sound"
  if (c == "video") return "playing video"
  if (c == "flashlight") return "flashlight"
  if (c == "system_services") return "asking Android to do work for it"
  if (c == "memory") return "memory"
  if (c == "phone") return "phone calls"
  if (c == "ambient_display") return "always-on display"
  if (c == "idle") return "standby"
  return ""
}
function hw_name(c) {
  if (c == "screen") return "Screen (lock screen, or no app open)"
  if (c == "idle") return "Phone asleep (standby)"
  if (c == "phone") return "Phone calls"
  if (c == "mobile_radio") return "Mobile network signal (standby)"
  if (c == "wifi") return "Wi-Fi (standby and scanning)"
  if (c == "bluetooth") return "Bluetooth (standby and scanning)"
  if (c == "ambient_display") return "Always-on display"
  if (c == "memory") return "Memory (RAM)"
  if (c == "cpu") return "Processor (not linked to one app)"
  if (c == "gnss") return "GPS (not linked to one app)"
  if (c == "flashlight") return "Flashlight"
  if (c == "camera") return "Camera"
  return "Other hardware (" c ")"
}
# Android 11 and older named their non-app lines in English.
function old_hw(n) {
  if (n == "Screen") return "screen"
  if (n == "Idle") return "idle"
  if (n == "Cell standby") return "mobile_radio"
  if (n == "Phone calls") return "phone"
  if (n == "Wifi") return "wifi"
  if (n == "Bluetooth") return "bluetooth"
  if (n == "Ambient display") return "ambient_display"
  if (n == "Memory") return "memory"
  if (n == "Flashlight") return "flashlight"
  if (n == "Camera") return "camera"
  return ""
}
function is_mine(a,   n, arr, i) {
  n = split(plist[a], arr, " ")
  for (i = 1; i <= n; i++) if (arr[i] in userpkg) return 1
  return 0
}
function app_label(a,   p, nm) {
  p = (a in fbest) ? fbest[a] : pk1[a]
  nm = (p in fname) ? fname[p] " (" p ")" : p
  if (npk[a] > 1) nm = nm " and " (npk[a] - 1) " more sharing it"
  return nm
}
# Friendly name for a UID token; also sets the global "kind".
function who(tok,   u, a, usr, nm) {
  u = uid_num(tok)
  if (u < 0) { kind = "sys"; return "Unknown (" tok ")" }
  a = u % 100000; usr = int(u / 100000)
  if (a < 10000) { kind = "sys"; nm = sys_name(a); if (usr > 0) nm = nm " (user " usr ")"; return nm }
  if (a >= 90000) { kind = "sys"; return "Helper process (" tok ")" }
  if (a in pk1) { kind = is_mine(a) ? "mine" : "pre"; nm = app_label(a) }
  else { kind = "gone"; nm = "App not found (ID " tok ", maybe uninstalled since)" }
  if (usr > 0) nm = nm " - second space or dual app"
  return nm
}
function tag(k) {
  if (k == "mine") return "[you installed it]"
  if (k == "pre") return "[came with the phone]"
  if (k == "sys") return "[part of Android]"
  if (k == "hw") return "[hardware, not an app]"
  return "[app not found]"
}
function add_cons(key, nm, k, mah, comps, bgtxt) {
  if (!(key in cmah)) { ncons++; ckey[ncons] = key; cmah[key] = 0 }
  cmah[key] += mah; cname[key] = nm; ckind[key] = k; ccomp[key] = ccomp[key] comps; cbg[key] = bgtxt
}
function why(list, total,   n, arr, i, c, v, b1, v1, b2, v2, r) {
  n = split(list, arr, " "); v1 = 0; v2 = 0; b1 = ""; b2 = ""
  for (i = 1; i <= n; i++) {
    c = arr[i]; v = c; sub(/=.*$/, "", c); sub(/^[^=]*=/, "", v); v = num(v)
    if (reason_of(c) == "" || v <= 0) continue
    if (v > v1) { b2 = b1; v2 = v1; b1 = c; v1 = v } else if (v > v2) { b2 = c; v2 = v }
  }
  if (b1 == "") return ""
  r = "Mainly: " reason_of(b1)
  if (b2 != "" && total > 0 && v2 >= 0.2 * total) r = r ", then " reason_of(b2)
  return r "."
}
function wl_hint(n,   l) {
  l = tolower(n)
  if (n ~ /^\*job\*/) return "mostly background tasks"
  if (n ~ /^\*w?alarm\*/) return "mostly alarms and timers"
  if (n ~ /^\*sync\*/) return "mostly account sync"
  if (l ~ /nlp|location|flp|fused|gps/) return "mostly location checks"
  return ""
}
function parse_uid(s,   tok, rest, n, tk, i, comps, tot, pre, fg, bgs, st, bgtxt, nm) {
  sub(/^(UID|Uid) /, "", s)
  tok = s; sub(/:.*$/, "", tok)
  rest = substr(s, length(tok) + 3)
  tot = num(rest)
  if (match(rest, /Including smearing: -?[0-9.]+/)) tot = num(substr(rest, RSTART + 20, RLENGTH - 20))
  n = split(rest, tk, " "); comps = ""; pre = 1; fg = 0; bgs = 0; st = 0
  for (i = 2; i <= n; i++) {
    if (tk[i] ~ /^\(/) pre = 0
    if (pre && i < n && tk[i] ~ /^(fg|bg|fgs|cached):$/) {
      st = 1
      if (tk[i] == "fg:") fg += num(tk[i + 1]); else bgs += num(tk[i + 1])
    }
    if (tk[i] ~ /^[a-z_]+=-?[0-9.]+$/) comps = comps " " tk[i]
  }
  bgtxt = ""
  if (st && fg + bgs > 0) {
    if (bgs / (fg + bgs) >= 0.6) bgtxt = "mostly in the background"
    else if (fg / (fg + bgs) >= 0.6) bgtxt = "mostly while open on screen"
  }
  nm = who(tok)
  add_cons("A:" tok, nm, kind, tot, comps, bgtxt)
}
function parse_est(line,   s, nm, rest, c) {
  s = line; sub(/^ +/, "", s)
  if (s ~ /^Capacity: /) {
    estcap_seen = 1
    if (match(s, /Computed drain: -?[0-9.]+/)) computed = num(substr(s, RSTART + 16, RLENGTH - 16))
    if (match(s, /^Capacity: [0-9.]+/)) estcap = substr(s, 11, RLENGTH - 10) + 0
    return
  }
  if (s == "Global") { inglob = 1; return }
  if (s ~ /^(UID|Uid) [^ ]+: /) { inglob = 0; parse_uid(s); return }
  if (s ~ /^User [0-9]+: /) {
    inglob = 0; nm = s; sub(/:.*$/, "", nm); rest = substr(s, length(nm) + 3)
    add_cons("U:" nm, "Another user on this phone (" nm ")", "sys", num(rest), "", "")
    return
  }
  if (inglob && line ~ /^      [^ ]/) {
    nm = s; sub(/:.*$/, "", nm)
    if (nm !~ /^[a-z_]+$/) return
    gdev[nm] = num(substr(s, length(nm) + 3)); gapps[nm] = 0
    if (match(s, / apps: -?[0-9.]+/)) gapps[nm] = num(substr(s, RSTART + 7, RLENGTH - 7))
    if (!(nm in gseen)) { gseen[nm] = 1; gorder[++ng] = nm }
    return
  }
  if (match(s, /^[A-Z][A-Za-z ]*: -?[0-9.]+/)) {
    nm = substr(s, 1, index(s, ":") - 1); c = old_hw(nm)
    if (c != "") add_cons("G:" c, hw_name(c), "hw", num(substr(s, length(nm) + 3)), "", "")
  }
}
function parse_wl(line,   s, tok, ms, nm) {
  s = line; sub(/^ *Wake lock /, "", s)
  tok = s; sub(/ .*$/, "", tok)
  if (!match(s, /: ([0-9]+d )?([0-9]+h )?([0-9]+m )?([0-9]+s )?[0-9]+ms \(/)) return
  ms = dur_ms(substr(s, RSTART + 2, RLENGTH - 3))
  nm = substr(s, length(tok) + 2, RSTART - length(tok) - 2)
  if (!(tok in wl)) { nwl++; wkey[nwl] = tok; wl[tok] = 0; wtopms[tok] = -1 }
  wl[tok] += ms
  if (ms > wtopms[tok]) { wtopms[tok] = ms; wtop[tok] = nm }
}
FILENAME == ARGV[1] { i = index($0, "|"); if (i > 1) fname[substr($0, 1, i - 1)] = substr($0, i + 1); next }
FILENAME == ARGV[2] {
  if ($0 !~ /^package:/ || !match($0, /uid:[0-9]+/)) next
  u = substr($0, RSTART + 4, RLENGTH - 4) + 0; a = u % 100000
  p = $1; sub(/^package:/, "", p)
  if ((a, p) in seenp) next
  seenp[a, p] = 1; npk[a]++; plist[a] = plist[a] " " p
  if (!(a in pk1) || p < pk1[a]) pk1[a] = p
  if ((p in fname) && (!(a in fbest) || p < fbest[a])) fbest[a] = p
  next
}
FILENAME == ARGV[3] { p = $1; sub(/^package:/, "", p); if (p != "") userpkg[p] = 1; next }
{
  line = $0
  if (line ~ /^Statistics since last charge:/) { since = 1; next }
  if (!since) next
  if (inest) {
    match(line, /[^ ]/)
    if (RSTART == 0 || RSTART <= 3) { inest = 0; inglob = 0 }
    else { parse_est(line); next }
  }
  if (inwl) {
    if (line ~ /^  Wake lock /) { parse_wl(line); next }
    inwl = 0
  }
  if (line ~ /Estimated power use \(mAh\):/) { inest = 1; estseen = 1; next }
  if (line ~ /^  All partial wake locks:/) { inwl = 1; next }
  if (line ~ /^  Time on battery: /) { onbat = dur_ms(upto_paren(substr(line, 20))); next }
  if (line ~ /^  Time on battery screen off: /) { offms = dur_ms(upto_paren(substr(line, 31))); offseen = 1; next }
  if (line ~ /^  Screen off discharge: /) { offmah = num(substr(line, 25)); next }
  if (line ~ /^  Estimated battery capacity: /) { est = num(substr(line, 31)); next }
  if (line ~ /^  Last learned battery capacity: /) { learned = num(substr(line, 34)); next }
  if (line ~ /^  Start clock time: /) {
    t = substr(line, 21)
    if (t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) start = substr(t, 1, 10) " " substr(t, 12, 2) ":" substr(t, 15, 2)
    next
  }
  if (line ~ /^  Total partial wakelock time: /) { pwltotal = dur_ms(substr(line, 32)); next }
  if (line ~ /^ *Amount discharged while screen off: /) { sub(/^.*: /, "", line); offpts = num(line); ptsseen = 1; next }
  if (line ~ /^ *Amount discharged while screen doze: /) { sub(/^.*: /, "", line); dozepts = num(line); next }
}
END {
  print "-- 1) What used the battery since the last full charge --"
  if (onbat > 0) {
    cov = "   These numbers cover " fmt_dur(onbat) " on battery"
    if (start != "") cov = cov ", counting from " start
    print cov "."
    if (onbat < 7200000) print "   That is not much yet. The numbers get more useful after a day of normal use."
  }
  for (i = 1; i <= ng; i++) {
    c = gorder[i]
    if (c == "reattributed") continue
    left = gdev[c] - gapps[c]
    if (left >= 0.05) add_cons("G:" c, hw_name(c), "hw", left, "", "")
  }
  total = computed
  if (total <= 0) { total = 0; for (i = 1; i <= ncons; i++) if (cmah[ckey[i]] > 0) total += cmah[ckey[i]] }
  cap = (learned > 0) ? learned : ((est > 0) ? est : estcap)
  if (!estseen) {
    print "   The phone did not include per-app battery numbers in its report (this Android"
    print "   version may use a format this tool does not know yet), so this part is skipped."
  } else if (ncons == 0 || total <= 0) {
    print "   Android has no per-app battery numbers yet (that part of its report is empty)."
    print "   Use the phone normally for a few hours off the charger, then run this again."
  } else {
    printf "   Everything together used about %s mAh", fmt_mah(total)
    if (cap > 0) printf " (a full battery holds about %d mAh)", cap
    print "."
    print "   Biggest battery users:"
    for (r = 1; r <= 10; r++) {
      best = 0; bk = ""
      for (i = 1; i <= ncons; i++) {
        k = ckey[i]
        if (k in used) continue
        if (bk == "" || cmah[k] > best) { best = cmah[k]; bk = k }
      }
      if (bk == "" || best <= 0) break
      used[bk] = 1
      printf "   %2d. %s  %s\n", r, cname[bk], tag(ckind[bk])
      l2 = sprintf("       %s mAh, %.1f%% of the total.", fmt_mah(best), best * 100 / total)
      w = (ckind[bk] == "hw") ? "Not linked to any one app." : why(ccomp[bk], best)
      if (w != "") l2 = l2 " " w
      if (cbg[bk] != "") l2 = l2 " Used " cbg[bk] "."
      print l2
    }
    print "   (An app you use a lot also gets the screen counted against it. That is normal.)"
  }

  print ""
  print "-- 2) Battery drain while the screen was off --"
  if (!offseen) {
    print "   Android did not report screen-off data, so this part is skipped."
  } else if (offms < 3600000) {
    print "   The screen was off on battery for only " fmt_dur(offms) " so far: not enough to judge."
    print "   Check again after a night off the charger."
  } else {
    pts = offpts + dozepts
    pm = (cap > 0 && offmah > 0) ? offmah * 100 / cap : -1
    pct = -1
    if (pm > 0 && pm <= 100 && (!ptsseen || (pm <= 2 * pts + 2 && pm >= pts / 2 - 2))) pct = pm
    else if (ptsseen) pct = pts
    if (pct < 0) {
      print "   Android did not report how much battery was used with the screen off, so this part is skipped."
    } else {
      rate = int(pct * 10 / (offms / 3600000) + 0.5) / 10
      printf "   The screen was off for %s on battery and used about %s%% of the battery.\n", fmt_dur(offms), fmt_pct(int(pct * 10 + 0.5) / 10)
      printf "   That is %.1f%% per hour: ", rate
      if (rate < 1) print "GOOD (under 1% per hour). The phone sleeps properly when you are not using it."
      else if (rate <= 2) print "OK (1-2% per hour is normal with many messages or a smartwatch)."
      else if (rate <= 3) print "BAD (over 2% per hour). Something wakes the phone often: see parts 3 and 4."
      else print "BAD (over 3% per hour). Something keeps the phone busy while you are not using it: see parts 3 and 4."
      printf "   At this rate, a night of 8 hours with the screen off costs about %d%% of the battery.\n", rate * 8 + 0.5
    }
  }

  print ""
  print "-- 3) Apps keeping the phone awake while the screen was off --"
  print "   (A \"wake lock\" is how an app stops the phone from going to sleep.)"
  if (nwl == 0) {
    print "   No app held the phone awake (or Android did not report it). Nothing to worry about here."
  } else {
    for (r = 1; r <= 5; r++) {
      best = -1; bk = ""
      for (i = 1; i <= nwl; i++) {
        k = wkey[i]
        if (k in wused) continue
        if (bk == "" || wl[k] > best) { best = wl[k]; bk = k }
      }
      if (bk == "" || best <= 0) break
      wused[bk] = 1
      nm = who(bk)
      l2 = sprintf("   %d. %s  %s: %s", r, nm, tag(kind), fmt_dur(best))
      h = wl_hint(wtop[bk])
      if (h != "") l2 = l2 " (" h ")"
      if (best >= 3600000) l2 = l2 "  <- that is a lot"
      print l2
    }
    if (pwltotal > 0) {
      l2 = "   All together, apps kept the phone awake for " fmt_dur(pwltotal)
      if (offms > 0) l2 = l2 sprintf(" (%d%% of the screen-off time)", pwltotal * 100 / offms + 0.5)
      print l2 "."
    }
    print "   A few minutes per app is normal. An hour or more from one app is a lot."
  }
  print "   To calm down an app you installed: Settings > Apps > Manage apps > (the app) >"
  print "   Battery saver > Restrict background activity. Do not do this for messaging, banking"
  print "   or OTP apps: their messages and codes could arrive late."
}'

bd_yes() { case "${1:-}" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac; }

bd_names() { printf '%s\n' "${BD_APP_NAMES[@]}"; }

# The BD_SETTINGS line for a key (empty if the key is not one of ours).
bd_entry() {
  local e
  for e in "${BD_SETTINGS[@]}"; do
    [ "${e%%|*}" = "$1" ] && { printf '%s\n' "$e"; return 0; }
  done
  return 1
}

bd_title() { local e t; e=$(bd_entry "$1") || return 1; t=${e#*|}; printf '%s\n' "${t%%|*}"; }

bd_valid_val() { case "${1:-}" in 0|1|null) return 0 ;; *) return 1 ;; esac; }

# Plain words for a saved value.
bd_word() {
  case "$2" in
    1) echo "on" ;;
    0) echo "off" ;;
    null)
      case "$1" in
        mobile_data_always_on) echo "on (the Android default)" ;;
        ble_scan_always_enabled) echo "off (the Android default)" ;;
        *) echo "the Android default" ;;
      esac ;;
    *) echo "$2" ;;
  esac
}

# Is the setting really on? Prints on, off or unknown.
# An unset value ("null") means the Android default: mobile data always active defaults to on,
# Bluetooth scanning to off; Wi-Fi scanning lives in the Wi-Fi service, so ask it directly.
bd_effective() {
  local s
  case "$2" in
    1) echo on ;;
    0) echo off ;;
    null)
      case "$1" in
        mobile_data_always_on) echo on ;;
        ble_scan_always_enabled) echo off ;;
        wifi_scan_always_enabled)
          s=$(ash cmd wifi status 2>/dev/null | grep -i 'scanning is')
          case "$s" in
            *"always available"*) echo on ;;
            *"only available"*) echo off ;;
            *) echo unknown ;;
          esac ;;
        *) echo unknown ;;
      esac ;;
    *) echo unknown ;;
  esac
}

bd_get() { ash settings get global "$1" 2>/dev/null | head -n 1 | tr -d ' \t'; }

bd_undo_has() { [ -f "$HOME/$BD_UNDO_NAME" ] && grep -q "^$1=" "$HOME/$BD_UNDO_NAME"; }

bd_undo_drop() {
  local f="$HOME/$BD_UNDO_NAME"
  [ -f "$f" ] || return 0
  grep -v "^$1=" "$f" >"$TMPD/bd_undo_tmp"
  if [ -s "$TMPD/bd_undo_tmp" ]; then cp "$TMPD/bd_undo_tmp" "$f"; else rm -f "$f"; fi
}

bd_undo_list() {
  local k v t
  while IFS='=' read -r k v <&3; do
    t=$(bd_title "$k") || continue
    echo "   - $t (it was $(bd_word "$k" "$v") before)"
  done 3<"$1"
}

# Put a setting back exactly: "null" means it was never set, so delete it again.
bd_restore() {
  if [ "$2" = null ]; then
    ash settings delete global "$1" >/dev/null 2>&1
    if [ "$(bd_get "$1")" != null ]; then
      echo "Could not change $1."
      echo "Turn on 'USB debugging (Security settings)' in Developer options (needs a SIM and Mi account), then try again."
      return 1
    fi
  else
    setg "$1" "$2" || return 1
  fi
}

bd_undo() {
  local f="$HOME/$BD_UNDO_NAME" keep="$TMPD/bd_keep" k v t a
  if [ ! -s "$f" ]; then
    echo "Nothing to undo: $f is empty or missing."
    return
  fi
  : >"$keep"
  echo "You will be asked about each change. Just pressing Enter means No (keep it as it is now)."
  while IFS='=' read -r k v <&3; do
    [ -n "$k" ] || continue
    if ! t=$(bd_title "$k") || ! bd_valid_val "$v"; then
      echo "  Skipping a line this tool does not recognise: $k"
      echo "$k=$v" >>"$keep"
      continue
    fi
    a=""
    read -r -p "Put $t back to $(bd_word "$k" "$v"), as it was before? [y/N] " a || a=""
    if ! bd_yes "$a"; then
      echo "  $t left as it is."
      echo "$k=$v" >>"$keep"
    elif bd_restore "$k" "$v"; then
      echo "  Done: $t is back to $(bd_word "$k" "$v")."
    else
      echo "  $t was not changed; it stays in the undo file so you can try again."
      echo "$k=$v" >>"$keep"
    fi
  done 3<"$f"
  if [ -s "$keep" ]; then
    cp "$keep" "$f"
    echo "Changes you kept are still saved in $f."
  else
    rm -f "$f"
    echo "All earlier changes are undone."
  fi
}

# Turn one hidden drain off: save the old value first, change it, read it back.
bd_turn_off() {
  local key=$1 raw=$2 title=$3 f="$HOME/$BD_UNDO_NAME" save added=0 s
  save=$raw
  # Unset Wi-Fi scanning that is on: deleting the setting later would leave it off, so save "1".
  if [ "$raw" = null ] && [ "$key" = wifi_scan_always_enabled ]; then save=1; fi
  if ! bd_undo_has "$key"; then
    { echo "$key=$save" >>"$f"; } 2>/dev/null
    if ! bd_undo_has "$key"; then
      echo "  Could not write the undo file $f, so nothing was changed."
      return 1
    fi
    added=1
  fi
  if setg "$key" 0; then
    echo "  Done: $title is now off. (The old value is saved in $f.)"
    echo "  To undo: run this option again and type u at the first question."
    if [ "$key" = wifi_scan_always_enabled ]; then
      s=$(ash cmd wifi status 2>/dev/null | grep -i 'scanning is')
      case "$s" in
        *"always available"*)
          echo "  Note: the phone still says Wi-Fi scanning is on. If it stays on, switch it off in"
          echo "  Settings > Location > Location services > Wi-Fi scanning." ;;
      esac
    fi
  else
    [ "$added" = 1 ] && bd_undo_drop "$key"
    echo "  $title was left as it was."
    return 1
  fi
}

# Part 4 of the report: read the three settings (read-only) and remember them for bd_fixes.
bd_settings_report() {
  local entry key title explain effect raw eff note
  echo
  echo "-- 4) Hidden battery drains (settings) --"
  : >"$TMPD/bd_states"
  for entry in "${BD_SETTINGS[@]}"; do
    IFS='|' read -r key title explain effect <<<"$entry"
    raw=$(bd_get "$key")
    eff=$(bd_effective "$key" "$raw")
    note=""
    [ "$raw" = null ] && note=" (the Android default)"
    case "$eff" in
      on) echo "   $title: ON$note" ;;
      off) echo "   $title: off$note. Good." ;;
      *) echo "   $title: could not be read (the phone answered '${raw:-nothing}'), so it is left alone." ;;
    esac
    echo "      $explain"
    echo "$key|$raw|$eff" >>"$TMPD/bd_states"
  done
}

bd_fixes() {
  local key raw eff entry dummy title explain effect a any=0
  while IFS='|' read -r key raw eff <&3; do
    [ "$eff" = on ] && any=1
  done 3<"$TMPD/bd_states"
  echo
  if [ "$any" = 0 ]; then
    echo "None of the hidden drains are switched on. Nothing to change."
    return
  fi
  echo "You can switch these off now. You will be asked about each one; just pressing Enter means No."
  while IFS='|' read -r key raw eff <&3; do
    [ "$eff" = on ] || continue
    entry=$(bd_entry "$key") || continue
    IFS='|' read -r dummy title explain effect <<<"$entry"
    echo "$title: $effect"
    a=""
    read -r -p "Turn $title off? [y/N] " a || a=""
    if bd_yes "$a"; then
      bd_turn_off "$key" "$raw" "$title"
    else
      echo "  $title left as it is."
    fi
  done 3<"$TMPD/bd_states"
}

# Shown instead of parts 1-3 when the phone did not hand over its battery statistics.
bd_unreadable() {
  local said
  said=$(grep -v '^[[:space:]]*$' "$1" | head -n 1 | cut -c 1-160)
  echo "-- 1-3) Battery statistics --"
  echo "   Could not read the battery statistics from the phone, so parts 1-3 are skipped."
  if [ -n "$said" ]; then echo "   What the phone said: $said"; else echo "   The phone sent back nothing."; fi
  echo "   Unlock the phone, check that USB debugging is still allowed, then try again."
}

battery_drain() {
  local f="$HOME/$BD_UNDO_NAME" a="" report model ver
  if [ -s "$f" ]; then
    echo "Earlier, this option switched off some battery settings (saved in $f):"
    bd_undo_list "$f"
    read -r -p "Type u to undo those changes, or just press Enter to run the battery check: " a || a=""
    case "$a" in
      u|U) bd_undo; return ;;
    esac
  fi
  report="battery-drain-$(date +%Y%m%d).txt"
  echo "Reading battery statistics from the phone (this can take up to 30 seconds)..."
  ash dumpsys batterystats --charged >"$TMPD/bd_stats" 2>&1
  ash pm list packages -U -u >"$TMPD/bd_pkgs" 2>/dev/null
  ash pm list packages -3 >"$TMPD/bd_user" 2>/dev/null
  bd_names >"$TMPD/bd_names"
  model=$(ash getprop ro.product.model)
  ver=$(ash getprop ro.build.version.release)
  {
    echo "== Battery drain detective, $(date +%Y-%m-%d) =="
    echo "Phone: ${model:-unknown} (Android ${ver:-?})"
    echo "Android resets these battery numbers every time the phone is fully charged,"
    echo "so this is most useful after a day of normal use off the charger."
    echo
    if grep -q '^Statistics since last charge:' "$TMPD/bd_stats"; then
      awk "$BD_AWK" "$TMPD/bd_names" "$TMPD/bd_pkgs" "$TMPD/bd_user" "$TMPD/bd_stats"
      grep -q 'package:' "$TMPD/bd_pkgs" || echo "   (Could not read the app list from the phone, so apps are shown by their ID.)"
    else
      bd_unreadable "$TMPD/bd_stats"
    fi
    bd_settings_report
  } >"$TMPD/bd_report"
  cat "$TMPD/bd_report"
  echo
  if cp "$TMPD/bd_report" "$report" 2>/dev/null; then
    echo "A copy of this report was saved to $(pwd)/$report"
  else
    echo "Could not save the report in $(pwd) (is the folder read-only?). It is shown above."
  fi
  bd_fixes
}
