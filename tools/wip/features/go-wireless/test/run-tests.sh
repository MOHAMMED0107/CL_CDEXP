#!/usr/bin/env bash
# Tests for the go-wireless feature (go_wireless + gw_pick_device). Exits 0 only if all pass.
# Uses the project harness (harness/feature-run.sh) with a fake adb (test/bin/adb) whose answers
# are modelled on real adb / Android 12 / MIUI 14 output, with \r\n line endings.
set -u
unset ANDROID_SERIAL

HERE=$(cd "$(dirname "$0")" && pwd)
FDIR=$(cd "$HERE/.." && pwd)
FEATURE="$FDIR/feature.sh"
BIN="$HERE/bin"
SCRATCH=$(cd "$FDIR/../.." && pwd)
HARNESS="$SCRATCH/harness/feature-run.sh"
MAIN="$SCRATCH/phone-pro.sh"
WORK="$HERE/tmp"
rm -rf "$WORK"
mkdir -p "$WORK"

PASS=0
FAIL=0
FAILED=""
N=0
T=""   # current test name
F=""   # fake phone state dir
H=""   # $HOME for the run
OUT="" # output of the run
RC=0

# ---------- building the fake world ----------

begin() {
  N=$((N + 1))
  T=$1
  local d="$WORK/$N"
  mkdir -p "$d/fake/phone" "$d/fake/knob" "$d/home"
  F="$d/fake"
  H="$d/home"
  OUT="$d/out.txt"
  : >"$F/transports"
  : >"$F/log"
}

# phone ID SERIALNO MODEL MARKETNAME IP
phone() {
  local p="$F/phone/$1"
  mkdir -p "$p/props"
  printf '%s' "$2" >"$p/props/ro.serialno"
  printf '%s' "$3" >"$p/props/ro.product.model"
  [ -n "$4" ] && printf '%s' "$4" >"$p/props/ro.product.marketname"
  printf '%s' "Xiaomi" >"$p/props/ro.product.manufacturer"
  printf '%s' "12" >"$p/props/ro.build.version.release"
  printf '%s' "$5" >"$p/ip"
  : >"$p/tcpport"
  echo "ip-addr-wlan0.txt" >"$p/wlan_addr"
  echo "ip-route.txt" >"$p/wlan_route"
  echo "37123" >"$p/pair_port"
  echo "482915" >"$p/pair_code"
  echo "41567" >"$p/tls_port"
}
pset() { printf '%s\n' "$3" >"$F/phone/$1/$2"; }
transport() { echo "$1|$2|$3" >>"$F/transports"; }
knob() { printf '%s' "${2:-1}" >"$F/knob/$1"; }

# The usual setup: one Redmi Note 9 Pro on the USB cable.
redmi_usb() {
  phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
  transport a1b2c3d4 device p1
}

snapshot() { rm -rf "$F.before"; mkdir -p "$F.before"; cp -R "$F/phone" "$F.before/phone"; cp "$F/transports" "$F.before/transports"; }
unchanged() { diff -r "$F.before/phone" "$F/phone" >/dev/null && diff "$F.before/transports" "$F/transports" >/dev/null; }

# run 'SHELL CODE' 'ANSWERS' [VAR=value ...]   (ANSWERS uses \n for Enter)
run() {
  local fn=$1 answers=$2
  shift 2
  printf '%b' "$answers" | env FAKE_ADB_DIR="$F" TEST_HOME="$H" "$@" \
    bash "$HARNESS" "$FEATURE" "$fn" "$BIN" >"$OUT" 2>&1
  RC=$?
}

# ---------- assertions ----------

ok() {
  if eval "$2"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED="$FAILED
  [$N] $T: $1"
    echo "FAIL [$N] $T: $1"
    echo "  check: $2"
    echo "  ---- output ----"
    sed 's/^/  | /' "$OUT" 2>/dev/null | tail -n 40
    echo "  ---- adb log ----"
    sed 's/^/  | /' "$F/log" 2>/dev/null | tail -n 25
  fi
}
has() { grep -qF -- "$1" "$OUT"; }
lacks() { ! grep -qF -- "$1" "$OUT"; }
log_has() { grep -qE -- "$1" "$F/log"; }
log_lacks() { ! grep -qE -- "$1" "$F/log"; }
tcpport() { cat "$F/phone/${2:-p1}/tcpport"; }
listed() { grep -q "^$1|$2|" "$F/transports"; }
not_listed() { ! grep -q "^$1|" "$F/transports"; }
no_unknown() { [ ! -s "$F/unknown" ]; }
# adb calls that change the phone or the connection
no_changes_sent() { log_lacks $'\t(tcpip|usb|pair|connect|disconnect) '; }

# =====================================================================
# go_wireless
# =====================================================================

begin "happy path: USB -> Wi-Fi"
redmi_usb
knob restart_polls 4
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"; echo "MODEL=$(ash getprop ro.product.model)"' 'y\n'
ok "exit code 0" '[ "$RC" = 0 ]'
ok "shows the Wi-Fi IP" 'has "Your phone'"'"'s Wi-Fi address: 192.168.1.42"'
ok "explains trusted Wi-Fi" 'has "Only do this on Wi-Fi you trust"'
ok "explains adb key" 'has "adb key"'
ok "tcpip sent to the USB serial" 'log_has "s=a1b2c3d4	tcpip 5555"'
ok "connect sent" 'log_has "	connect 192.168.1.42:5555"'
ok "verified with get-state on the Wi-Fi serial" 'log_has "s=192.168.1.42:5555	get-state"'
ok "phone now listens on 5555" '[ "$(tcpport)" = 5555 ]'
ok "Wi-Fi connection listed as device" 'listed 192.168.1.42:5555 device'
ok "ANDROID_SERIAL exported" 'has "AFTER=192.168.1.42:5555"'
ok "later ash call goes over Wi-Fi" 'has "MODEL=Redmi Note 9 Pro" && log_has "^env=192.168.1.42:5555	s=	shell getprop ro.product.model"'
ok "says unplug now" 'has "You can unplug the USB cable now"'
ok "says it lasts until restart" 'has "until the phone restarts"'
ok "read-back of the port" 'has "listening on Wi-Fi port 5555"'
ok "undo file saved" 'grep -q "^wifi_serial=192.168.1.42:5555$" "$H/phone-pro-wifi-undo.txt" && grep -q "^usb_serial=a1b2c3d4$" "$H/phone-pro-wifi-undo.txt" && grep -q "^how=tcpip$" "$H/phone-pro-wifi-undo.txt"'
ok "waited for adbd restart (polled the USB serial)" '[ "$(grep -c "s=a1b2c3d4	get-state" "$F/log")" -ge 3 ]'
ok "only known adb commands used" 'no_unknown'

begin "Enter to everything: nothing changes"
redmi_usb
snapshot
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' '\n\n\n\n\n\n'
ok "exit code 0" '[ "$RC" = 0 ]'
ok "says nothing was changed" 'has "nothing was changed"'
ok "phone state unchanged" 'unchanged'
ok "no tcpip/usb/connect/pair sent" 'no_changes_sent'
ok "no undo file" '[ ! -f "$H/phone-pro-wifi-undo.txt" ]'
ok "ANDROID_SERIAL left alone" 'has "AFTER=unset"'

begin "No input at all (end of input): nothing changes"
redmi_usb
snapshot
run 'go_wireless' ''
ok "exit code 0" '[ "$RC" = 0 ]'
ok "phone state unchanged" 'unchanged'
ok "no changes sent" 'no_changes_sent'

begin "Typing 'n' is No"
redmi_usb
snapshot
run 'go_wireless' 'n\n'
ok "phone state unchanged" 'unchanged && no_changes_sent'

begin "Not on Wi-Fi (ip addr empty, route mobile only)"
redmi_usb
pset p1 wlan_addr ip-addr-wlan0-noip.txt
pset p1 wlan_route ip-route-mobile.txt
snapshot
run 'go_wireless' '\n'
ok "exit code 0" '[ "$RC" = 0 ]'
ok "clear message" 'has "not connected to Wi-Fi"'
ok "does not use the mobile-data address" 'lacks "100.71.66.157"'
ok "nothing changed" 'unchanged && no_changes_sent'

begin "Wi-Fi off (wlan0 missing, empty route)"
redmi_usb
pset p1 wlan_addr ip-addr-wlan0-missing.err
: >"$F/phone/p1/wlan_route"
snapshot
run 'go_wireless' '\n'
ok "clear message, no crash" '[ "$RC" = 0 ] && has "Could not find your phone'"'"'s Wi-Fi address"'
ok "nothing changed" 'unchanged && no_changes_sent'

begin "ip addr unreadable, falls back to ip route"
redmi_usb
pset p1 wlan_addr ip-addr-denied.err
run 'go_wireless' 'y\n'
ok "found IP from ip route" 'has "Wi-Fi address: 192.168.1.42"'
ok "switched" '[ "$(tcpport)" = 5555 ] && listed 192.168.1.42:5555 device'

begin "Both unreadable: user types the IP"
redmi_usb
pset p1 wlan_addr ip-addr-denied.err
pset p1 wlan_route ip-route-denied.err
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' ' 192.168.1.42 \ny\n'
ok "asked and used the typed IP" 'has "Wi-Fi address: 192.168.1.42" && has "AFTER=192.168.1.42:5555"'

begin "Both unreadable: user types nonsense"
redmi_usb
pset p1 wlan_addr ip-addr-denied.err
pset p1 wlan_route ip-route-denied.err
snapshot
run 'go_wireless' '192.168.1\n'
ok "explains the format" 'has "does not look like an IP address"'
ok "nothing changed" 'unchanged && no_changes_sent'

begin "tcpip refused (error: closed), user declines pairing"
redmi_usb
knob tcpip closed
snapshot
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n\n'
ok "exit code 0" '[ "$RC" = 0 ]'
ok "says the phone refused" 'has "The phone refused to switch to Wi-Fi mode. It said: error: closed"'
ok "explains Wireless debugging step by step" 'has "Pair device with pairing code" && has "Developer options" && has "adb pair IP:PORT CODE"'
ok "no pairing attempted" 'log_lacks "	pair "'
ok "phone unchanged" 'unchanged'
ok "no undo file left" '[ ! -f "$H/phone-pro-wifi-undo.txt" ]'
ok "still on USB" 'has "AFTER=unset"'

begin "tcpip refused -> Wireless debugging pairing works"
redmi_usb
knob tcpip closed
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"; echo "MODEL=$(ash getprop ro.product.model)"' 'y\ny\n192.168.1.42:37123\n482 915\n41567\n'
ok "paired" 'has "Paired. This computer is now on the phone" && [ -f "$F/phone/p1/paired" ]'
ok "pair command exact" 'log_has "	pair 192.168.1.42:37123 482915"'
ok "port-only answer used the pairing IP" 'log_has "	connect 192.168.1.42:41567"'
ok "connected and exported" 'has "AFTER=192.168.1.42:41567" && has "MODEL=Redmi Note 9 Pro"'
ok "says pairing must be removed on the phone" 'has "Forget"'
ok "undo file records pairing" 'grep -q "^how=pair$" "$H/phone-pro-wifi-undo.txt" && grep -q "^wifi_serial=192.168.1.42:41567$" "$H/phone-pro-wifi-undo.txt"'

begin "Pairing: wrong code, then give up"
redmi_usb
knob tcpip closed
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\ny\n192.168.1.42:37123\n111111\n\n'
ok "shows adb's failure" 'has "Pairing did not work. adb said: Failed: Wrong password or connection was dropped."'
ok "not paired, not connected" '[ ! -f "$F/phone/p1/paired" ] && has "AFTER=unset" && log_lacks "	connect "'
ok "no undo file" '[ ! -f "$H/phone-pro-wifi-undo.txt" ]'

begin "Pairing: wrong code, retry with right code"
redmi_usb
knob tcpip closed
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\ny\n192.168.1.42:37123\n111111\ny\n192.168.1.42:37123\n482915\n192.168.1.42:41567\n'
ok "second try works" '[ -f "$F/phone/p1/paired" ] && has "AFTER=192.168.1.42:41567"'

begin "Pairing: bad code format"
redmi_usb
knob tcpip closed
run 'go_wireless' 'y\ny\n192.168.1.42:37123\n12ab\n'
ok "explains code format" 'has "The code must be the 6 digits"'
ok "no pair sent" 'log_lacks "	pair "'

begin "Pairing: adb too old (platform-tools 29)"
redmi_usb
knob tcpip closed
knob version adb-version-29.txt
run 'go_wireless' 'y\ny\n'
ok "tells user to update platform-tools" 'has "too old for Wireless debugging" && has "platform-tools"'
ok "no pair sent" 'log_lacks "	pair "'

begin "Pairing: very old adb (1.0.39, no Version line)"
redmi_usb
knob tcpip closed
knob version adb-version-old.txt
run 'go_wireless' 'y\ny\n'
ok "tells user to update" 'has "too old for Wireless debugging"'

begin "Pairing: newer adb auto-connects by mDNS too"
redmi_usb
knob tcpip closed
knob mdns
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"; echo "MODEL=$(ash getprop ro.product.model)"' 'y\ny\n192.168.1.42:37123\n482915\n41567\n'
ok "three connections exist, ANDROID_SERIAL picks one" 'has "AFTER=192.168.1.42:41567" && has "MODEL=Redmi Note 9 Pro"'

begin "MIUI ignores tcpip: connect refused, user keeps it, declines pairing"
redmi_usb
knob tcpip noop
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n\n\n'
ok "shows adb's refusal" 'has "Could not connect over Wi-Fi. adb said: failed to connect to '"'"'192.168.1.42:5555'"'"': Connection refused"'
ok "lists common reasons" 'has "AP isolation" && has "different network"'
ok "retried connect 3 times" '[ "$(grep -c "	connect 192.168.1.42:5555" "$F/log")" = 3 ]'
ok "offers pairing" 'has "Pair device with pairing code"'
ok "left as is when user says No" 'has "Left as is" && log_lacks "	usb "'
ok "undo file kept for later" '[ -f "$H/phone-pro-wifi-undo.txt" ]'
ok "still USB" 'has "AFTER=unset"'

begin "Connect fails, user switches phone back to USB-only (undo)"
redmi_usb
knob unreachable
knob connect_fail "cannot connect to 192.168.1.42:5555: A connection attempt failed because the connected party did not properly respond after a period of time, or established connection failed because connected host has failed to respond. (10060)"
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\ny\n\n'
ok "Windows-style failure shown" 'has "(10060)"'
ok "usb sent to the USB serial" 'log_has "s=a1b2c3d4	usb "'
ok "phone back to USB-only" '[ "$(tcpport)" = 0 ]'
ok "undo file removed" '[ ! -f "$H/phone-pro-wifi-undo.txt" ]'
ok "confirms" 'has "Done: the phone is back in USB-only mode."'

begin "Phone asks to Allow the Wi-Fi connection, user taps Allow"
redmi_usb
knob auth unauth_then_ok
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n'
ok "tells the user to tap Allow (once)" '[ "$(grep -c "unlock it and tap \"Allow\"" "$OUT")" = 1 ]'
ok "connected" 'has "AFTER=192.168.1.42:5555" && listed 192.168.1.42:5555 device'

begin "Phone never allows the Wi-Fi connection: undo offered"
redmi_usb
knob auth unauthorized
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\ny\n'
ok "explains" 'has "did not accept"'
ok "Allow hint shown once" '[ "$(grep -c "unlock it and tap" "$OUT")" = 1 ]'
ok "not exported" 'has "AFTER=unset"'
ok "phone back to USB-only after yes" '[ "$(tcpport)" = 0 ]'

begin "Go wireless then back to USB in one session (cable still in)"
redmi_usb
run 'go_wireless; echo "MID=${ANDROID_SERIAL:-unset}"; go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"; echo "MODEL=$(ash getprop ro.product.model)"' 'y\ny\n'
ok "was wireless in between" 'has "MID=192.168.1.42:5555"'
ok "second run recognises Wi-Fi mode" 'has "You are connected over Wi-Fi right now"'
ok "disconnect sent" 'log_has "	disconnect 192.168.1.42:5555"'
ok "usb sent to USB serial" 'log_has "s=a1b2c3d4	usb "'
ok "phone back to USB-only" '[ "$(tcpport)" = 0 ]'
ok "Wi-Fi connection gone" 'not_listed 192.168.1.42:5555'
ok "ANDROID_SERIAL unset" 'has "AFTER=unset"'
ok "ash works over USB again" 'has "MODEL=Redmi Note 9 Pro"'
ok "read-back confirmed" 'has "no longer listening on Wi-Fi"'
ok "undo file removed" '[ ! -f "$H/phone-pro-wifi-undo.txt" ]'

begin "Already wireless, user presses Enter: stays on Wi-Fi"
redmi_usb
pset p1 tcpport 5555
transport 192.168.1.42:5555 device p1
snapshot
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' '\n' ANDROID_SERIAL=192.168.1.42:5555
ok "staying" 'has "staying on Wi-Fi" && has "AFTER=192.168.1.42:5555"'
ok "nothing changed" 'unchanged && no_changes_sent'

begin "Back to USB with the cable unplugged: user says No to the extra question"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
pset p1 tcpport 5555
transport 192.168.1.42:5555 device p1
snapshot
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n\n' ANDROID_SERIAL=192.168.1.42:5555
ok "warns the cable is not plugged in" 'has "The USB cable is not plugged in"'
ok "nothing changed" 'unchanged && no_changes_sent && has "AFTER=192.168.1.42:5555"'

begin "Back to USB with the cable unplugged: user confirms"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
pset p1 tcpport 5555
transport 192.168.1.42:5555 device p1
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\ny\n' ANDROID_SERIAL=192.168.1.42:5555
ok "usb sent over Wi-Fi" 'log_has "s=192.168.1.42:5555	usb "'
ok "phone back to USB-only" '[ "$(tcpport)" = 0 ]'
ok "connection removed" 'not_listed 192.168.1.42:5555'
ok "asks to plug the cable in" 'has "Plug the USB cable in"'
ok "ANDROID_SERIAL unset" 'has "AFTER=unset"'

begin "Wi-Fi connection lost (phone restarted): Enter to everything"
redmi_usb
transport 192.168.1.42:5555 offline p1
knob startup_ok
snapshot
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' '\n\n' ANDROID_SERIAL=192.168.1.42:5555
ok "explains the drop" 'has "is not working right now (adb says: offline)"'
ok "nothing changed" 'unchanged && no_changes_sent'

begin "Wi-Fi connection lost: reconnect fails, back to USB"
redmi_usb
transport 192.168.1.42:5555 offline p1
knob startup_ok
cat >"$H/phone-pro-wifi-undo.txt" <<'EOF'
date=2026-10-10 09:00
how=tcpip
usb_serial=a1b2c3d4
wifi_serial=192.168.1.42:5555
old_tcp_port=
EOF
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"; echo "MODEL=$(ash getprop ro.product.model)"' 'y\ny\n' ANDROID_SERIAL=192.168.1.42:5555
ok "tried to reconnect" 'log_has "	connect 192.168.1.42:5555" && has "Could not reconnect"'
ok "found the phone on the cable via the undo file" 'log_has "s=a1b2c3d4	usb "'
ok "back on USB" 'has "Back on the USB cable" && has "AFTER=unset" && has "MODEL=Redmi Note 9 Pro"'
ok "stale connection removed" 'not_listed 192.168.1.42:5555'
ok "undo file removed" '[ ! -f "$H/phone-pro-wifi-undo.txt" ]'

begin "Wi-Fi connection lost: reconnect works"
redmi_usb
pset p1 tcpport 5555
transport 192.168.1.42:5555 offline p1
knob startup_ok
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n' ANDROID_SERIAL=192.168.1.42:5555
ok "reconnected" 'has "Reconnected" && has "AFTER=192.168.1.42:5555" && listed 192.168.1.42:5555 device'

begin "Script restarted: phone on USB and Wi-Fi from earlier, user switches to Wi-Fi"
redmi_usb
pset p1 tcpport 5555
transport 192.168.1.42:5555 device p1
snapshot
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n' ANDROID_SERIAL=a1b2c3d4
ok "notices earlier Wi-Fi connection" 'has "already connected over Wi-Fi too (192.168.1.42:5555)"'
ok "uses it without touching the phone" 'has "AFTER=192.168.1.42:5555" && unchanged && no_changes_sent'

begin "Script restarted: phone on USB and Wi-Fi, user turns Wi-Fi off"
redmi_usb
pset p1 tcpport 5555
transport 192.168.1.42:5555 device p1
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' '\ny\n' ANDROID_SERIAL=a1b2c3d4
ok "switched off" '[ "$(tcpport)" = 0 ] && not_listed 192.168.1.42:5555 && has "AFTER=unset"'

begin "Wireless debugging connection: back to USB only disconnects"
redmi_usb
pset p1 paired ""
transport 192.168.1.42:41567 device p1
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n' ANDROID_SERIAL=192.168.1.42:41567
ok "disconnected, no adbd restart" 'log_has "	disconnect 192.168.1.42:41567" && log_lacks "	usb "'
ok "explains how to switch Wireless debugging off" 'has "switch off \"Wireless debugging\""'
ok "back on USB" 'has "AFTER=unset" && not_listed 192.168.1.42:41567'

begin "Windows output: daemon start-up lines before the device list"
redmi_usb
knob daemon_msgs
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' 'y\n'
ok "still works" 'has "AFTER=192.168.1.42:5555"'

# =====================================================================
# gw_pick_device (startup check)
# =====================================================================
PICK='gw_pick_device; echo "RC=$? PICKED=${ANDROID_SERIAL:-unset}"'

begin "pick: one phone"
redmi_usb
run "$PICK" ''
ok "picked automatically" 'has "RC=0 PICKED=a1b2c3d4" && has "Phone found: Redmi Note 9 Pro (over USB cable, serial a1b2c3d4)."'
ok "model read with getprop" 'log_has "s=a1b2c3d4	shell getprop ro.product.marketname; getprop ro.product.model"'

begin "pick: no device"
knob startup_ok
run "$PICK" ''
ok "old message kept" 'has "No phone found. Check the cable, unlock the phone"'
ok "prints adb devices" 'has "List of devices attached"'
ok "offers Wireless debugging" 'has "No cable?"'
ok "returns 1" 'has "RC=1 PICKED=unset"'

begin "pick: no device, user connects over Wi-Fi with pairing"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
knob startup_ok
run "$PICK; echo \"MODEL=\$(ash getprop ro.product.model)\"" 'y\n192.168.1.42:37123\n482915\n192.168.1.42:41567\n'
ok "paired and connected without a cable" 'has "RC=0 PICKED=192.168.1.42:41567" && has "MODEL=Redmi Note 9 Pro"'

begin "pick: unauthorized only, user never taps Allow"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
transport a1b2c3d4 unauthorized p1
knob startup_ok
run "$PICK" '\n\n\n\n\n\n\n'
ok "tells the user to unlock and Allow" 'has "Unlock the phone and tap \"Allow\""'
ok "gives up after a few tries" 'has "RC=1 PICKED=unset" && has "start this script again"'
ok "full advice shown once, then short" '[ "$(grep -c "waiting for your OK" "$OUT")" = 1 ] && has "Still not ready."'
ok "no shell commands on an unauthorized device" 'log_lacks "	shell "'

begin "pick: unauthorized, user taps Allow then presses Enter"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
transport a1b2c3d4 unauthorized p1
mkdir -p "$F/flip"
echo "2 device" >"$F/flip/a1b2c3d4"
echo "a1b2c3d4" >"$F/flip/a1b2c3d4.serial"
knob startup_ok
run "$PICK" '\n\n\n'
ok "picked after Allow" 'has "RC=0 PICKED=a1b2c3d4"'

begin "pick: offline USB device"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
transport a1b2c3d4 offline p1
knob startup_ok
run "$PICK" 'q\n'
ok "advice for offline" 'has "Unplug the cable and plug it back in"'
ok "q quits" 'has "RC=1 PICKED=unset"'

begin "pick: Linux no-permissions state (with spaces)"
transport a1b2c3d4 "no permissions (missing udev rules? user is in the plugdev group); see [http://developer.android.com/tools/device.html]" p1
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
knob startup_ok
run "$PICK" ''
ok "advice for udev" 'has "not allowed to use the phone'"'"'s USB connection"'
ok "returns 1" 'has "RC=1"'

begin "pick: recovery and bootloader"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
transport a1b2c3d4 recovery p1
transport 0123456789ABCDEF bootloader p1
knob startup_ok
run "$PICK" ''
ok "recovery advice" 'has "recovery mode"'
ok "bootloader advice" 'has "fastboot (bootloader) mode"'

begin "pick: same phone over USB and Wi-Fi, user picks Wi-Fi"
redmi_usb
pset p1 tcpport 5555
transport 192.168.1.42:5555 device p1
knob startup_ok
run "$PICK" '2\n'
ok "lists both with names" 'has "1) Redmi Note 9 Pro" && has "2) Redmi Note 9 Pro" && has "over Wi-Fi, 192.168.1.42:5555"'
ok "marks the same phone" 'has "(same phone as 1)"'
ok "picked Wi-Fi" 'has "RC=0 PICKED=192.168.1.42:5555"'

begin "pick: two phones, Enter picks 1"
redmi_usb
phone p2 R58N12ABCDE "SM-A525F" "" 192.168.1.77
transport R58N12ABCDE device p2
knob startup_ok
run "$PICK" '\n'
ok "model fallback without marketname" 'has "SM-A525F"'
ok "no same-phone note" 'lacks "same phone"'
ok "Enter picks 1" 'has "RC=0 PICKED=a1b2c3d4"'

begin "pick: two phones, bad answers then 2"
redmi_usb
phone p2 R58N12ABCDE "SM-A525F" "" 192.168.1.77
transport R58N12ABCDE device p2
knob startup_ok
run "$PICK" '9\nabc\n2\n'
ok "asks again" 'has "Please type a number from 1 to 2."'
ok "picked 2" 'has "RC=0 PICKED=R58N12ABCDE"'

begin "pick: two phones, end of input -> nothing chosen"
redmi_usb
phone p2 R58N12ABCDE "SM-A525F" "" 192.168.1.77
transport R58N12ABCDE device p2
knob startup_ok
run "$PICK" ''
ok "returns 1" 'has "No device chosen." && has "RC=1 PICKED=unset"'

begin "pick: one ready + one unauthorized"
redmi_usb
phone p2 R58N12ABCDE "SM-A525F" "" 192.168.1.77
transport R58N12ABCDE unauthorized p2
knob startup_ok
run "$PICK; echo \"MODEL=\$(ash getprop ro.product.model)\"" ''
ok "uses the ready one" 'has "RC=0 PICKED=a1b2c3d4" && has "MODEL=Redmi Note 9 Pro"'
ok "mentions the other" 'has "Also connected, but not used:" && has "R58N12ABCDE: waiting for your OK"'

begin "pick: ANDROID_SERIAL already set and present (respected, no question)"
redmi_usb
phone p2 R58N12ABCDE "SM-A525F" "" 192.168.1.77
transport R58N12ABCDE device p2
run "$PICK" '' ANDROID_SERIAL=R58N12ABCDE
ok "respected" 'has "RC=0 PICKED=R58N12ABCDE" && has "Using the device set in ANDROID_SERIAL: SM-A525F"'
ok "no list shown" 'lacks "Which one"'

begin "pick: ANDROID_SERIAL set but missing"
redmi_usb
knob startup_ok
run "$PICK" '' ANDROID_SERIAL=ZZZ999
ok "clear message" 'has "ANDROID_SERIAL is set to '"'"'ZZZ999'"'"', but no device with that name is connected."'
ok "does not silently switch phones" 'has "RC=1"'

begin "pick: ANDROID_SERIAL=IP:5555 not connected yet, phone listening"
redmi_usb
pset p1 tcpport 5555
knob startup_ok
run "$PICK" '' ANDROID_SERIAL=192.168.1.42:5555
ok "connects by itself and uses it" 'log_has "	connect 192.168.1.42:5555" && has "RC=0 PICKED=192.168.1.42:5555"'

begin "pick: go_wireless with two devices and no ANDROID_SERIAL asks first"
redmi_usb
phone p2 R58N12ABCDE "SM-A525F" "" 192.168.1.77
transport R58N12ABCDE device p2
knob startup_ok
run 'go_wireless; echo "AFTER=${ANDROID_SERIAL:-unset}"' '1\ny\n'
ok "asked which device" 'has "Which one should this script use?"'
ok "then switched the chosen one" 'log_has "s=a1b2c3d4	tcpip 5555" && has "AFTER=192.168.1.42:5555"'

# =====================================================================
# Integration: main script with its startup check replaced as notes.md says
# =====================================================================

build_integrated() {
  # Paste feature.sh after `need adb`, replace the startup check with gw_pick_device.
  awk -v feat="$FEATURE" '
    /^while true; do$/ { exit }
    /^if ! adb get-state >\/dev\/null 2>&1; then$/ { skip = 1; next }
    skip && /^fi$/ { skip = 0; print "gw_pick_device || exit 1"; next }
    skip { next }
    { print }
    /^need adb$/ { while ((getline l < feat) > 0) print l }
  ' "$MAIN" >"$1"
  printf '\n%s\n' "$2" >>"$1"
}

begin "integration: two devices at startup, pick 2, then options run on it"
redmi_usb
phone p2 R58N12ABCDE "SM-A525F" "" 192.168.1.77
transport R58N12ABCDE device p2
build_integrated "$WORK/$N/integrated.sh" 'echo "PICKED=$ANDROID_SERIAL"; echo "MODEL=$(ash getprop ro.product.model)"'
printf '2\n' | env FAKE_ADB_DIR="$F" PATH="$BIN:$PATH" HOME="$H" bash "$WORK/$N/integrated.sh" >"$OUT" 2>&1
RC=$?
ok "startup check replaced" '! grep -q "^if ! adb get-state" "$WORK/$N/integrated.sh" && grep -q "^gw_pick_device || exit 1$" "$WORK/$N/integrated.sh"'
ok "runs and picks" '[ "$RC" = 0 ] && has "PICKED=R58N12ABCDE" && has "MODEL=SM-A525F"'

begin "integration: no device at startup exits 1 with the old message"
build_integrated "$WORK/$N/integrated.sh" 'echo SHOULD_NOT_RUN'
printf '' | env FAKE_ADB_DIR="$F" PATH="$BIN:$PATH" HOME="$H" bash "$WORK/$N/integrated.sh" >"$OUT" 2>&1
RC=$?
ok "exit 1" '[ "$RC" = 1 ] && has "No phone found" && lacks SHOULD_NOT_RUN'

begin "integration: unauthorized at startup exits 1 with advice"
phone p1 a1b2c3d4 "Redmi Note 9 Pro" "Redmi Note 9 Pro" 192.168.1.42
transport a1b2c3d4 unauthorized p1
build_integrated "$WORK/$N/integrated.sh" 'echo SHOULD_NOT_RUN'
printf 'q\n' | env FAKE_ADB_DIR="$F" PATH="$BIN:$PATH" HOME="$H" bash "$WORK/$N/integrated.sh" >"$OUT" 2>&1
RC=$?
ok "exit 1 with advice" '[ "$RC" = 1 ] && has "tap \"Allow\"" && lacks SHOULD_NOT_RUN'

# =====================================================================
# Static checks on feature.sh
# =====================================================================

begin "static: syntax and no top-level commands"
: >"$OUT"
ok "bash -n" 'bash -n "$FEATURE" 2>"$OUT"'
# Source it in a clean shell: it must print nothing and call nothing.
env -i PATH="$BIN:/usr/bin:/bin" FAKE_ADB_DIR="$F" HOME="$H" bash -c '
  set -u
  before=$(compgen -v | sort)
  . "$1" || exit 9
  after=$(compgen -v | sort)
  echo "NEWVARS:" $(comm -13 <(echo "$before") <(echo "$after") | grep -v -e "^before$" -e "^BASH_" -e "^_$")
  echo "FUNCS:" $(declare -F | awk "{ print \$3 }")
' _ "$FEATURE" >"$OUT" 2>&1
ok "sourcing prints nothing else and calls no adb" '[ "$(grep -c -v -e "^NEWVARS:" -e "^FUNCS:" "$OUT")" = 0 ] && [ ! -s "$F/log" ]'
ok "every function is go_wireless or gw_*" '[ -z "$(sed -n "s/^FUNCS: //p" "$OUT" | tr " " "\n" | grep -v -e "^go_wireless$" -e "^gw_" -e "^$")" ]'
ok "every global variable starts with GW_ or gw_" '[ -z "$(sed -n "s/^NEWVARS: *//p" "$OUT" | tr " " "\n" | grep -v -e "^GW_" -e "^gw_" -e "^$")" ]'
ok "names do not clash with the main script" '[ -z "$(grep -oE "^[a-z_]+\(\)" "$MAIN" | tr -d "()" | grep -xF -f <(sed -n "s/^FUNCS: //p" "$OUT" | tr " " "\n"))" ]'

begin "static: bash 3.2 / portable awk / no GNU-only tools"
code=$(sed 's/^[[:space:]]*#.*$//' "$FEATURE")
for pat in 'declare -A' 'mapfile' 'readarray' '\$\{[A-Za-z_]+,,' '\$\{[A-Za-z_]+\^\^' '&>>' 'sed -i' 'grep -P' 'date -d' 'stat -c' 'readlink -f' 'sort -h' 'du -b' 'numfmt' '(^|[^a-z_])timeout ' 'gensub' 'asort' 'strftime' 'systime' '\\y' 'local -n' 'coproc'; do
  if printf '%s\n' "$code" | grep -Eq -- "$pat"; then
    ok "no '$pat'" 'false'
  else
    ok "no '$pat'" 'true'
  fi
done
# awk regex intervals like {2} or {1,3}
ok "no awk regex intervals" '! printf "%s\n" "$code" | grep -Eq "/[^/]*[]a-z)][{][0-9]+(,[0-9]*)?[}][^/]*/"'
ok "line-reading loops read from fd 3" '[ -z "$(printf "%s\n" "$code" | grep -E "while .*read " | grep -v "<&3")" ]'
ok "every adb call keeps the keyboard (</dev/null)" '[ -z "$(printf "%s\n" "$code" | grep -E "(^|[^_a-z])adb " | grep -v "</dev/null" | grep -v "^ *echo" | grep -vE "(say|echo).*\"")" ]'

SC=""
if command -v shellcheck >/dev/null 2>&1; then SC=shellcheck; elif [ -x "$HERE/.tools/bin/shellcheck" ]; then SC="$HERE/.tools/bin/shellcheck"; fi
if [ -n "$SC" ]; then
  begin "static: shellcheck"
  # SC2034: GW_ constants used by other files; SC2154/SC2153: ash/TMPD come from the main script.
  "$SC" -s bash -S warning -e SC2034,SC2154,SC2153 "$FEATURE" >"$OUT" 2>&1
  RC=$?
  ok "shellcheck clean" '[ "$RC" = 0 ]'
fi

# ---------- summary ----------
echo
echo "go-wireless tests: $PASS passed, $FAIL failed ($N test groups)"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:$FAILED"
  exit 1
fi
[ -n "${KEEP:-}" ] || rm -rf "$WORK" # KEEP=1 keeps every run's output in test/tmp
exit 0
