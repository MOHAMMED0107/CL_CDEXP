# ---------- Go wireless: use the phone over Wi-Fi instead of the USB cable ----------
# go_wireless    : menu option. Switches to Wi-Fi (adb tcpip + adb connect), or back to USB.
# gw_pick_device : startup check. Copes with 0, 1 or several devices and exports ANDROID_SERIAL.
# Only function definitions and constants live here. Nothing below needs root.
# gw_pick_device runs BEFORE the main script defines ash/TMPD, so it (and everything it calls)
# talks to adb directly instead of using those helpers.

GW_PORT=5555
GW_UNDO="$HOME/phone-pro-wifi-undo.txt"
GW_TAB=$'\t'
gw_msg=""
gw_told=0

# ---- small helpers ----

# Host-side adb command, stdout+stderr together, Windows \r removed, never reads the keyboard.
gw_adb() { adb "$@" </dev/null 2>&1 | tr -d '\r'; }
# Run one command on a specific device (stderr dropped: empty output means "could not read").
gw_sh() { adb -s "$1" shell "$2" </dev/null 2>/dev/null | tr -d '\r'; }
# "device" when the device is ready to use, otherwise empty.
gw_state() { adb -s "$1" get-state </dev/null 2>/dev/null | tr -d '\r' | head -n 1; }

# Connected devices as "serial<TAB>state" lines, parsed from `adb devices`.
# Lines before the header (adb server start-up messages) and lines without a tab are skipped.
gw_devices() {
  adb devices </dev/null 2>/dev/null | tr -d '\r' | awk -F '\t' '
    /^List of devices attached/ { on = 1; next }
    on && NF >= 2 && $1 != "" { print $1 "\t" $2 }'
}

# State of one device as `adb devices` shows it (empty if it is not listed).
gw_dev_state() { gw_devices | awk -F '\t' -v s="$1" '$1 == s { print $2; exit }'; }

# Number of listed devices other than $1.
gw_others() { gw_devices | awk -F '\t' -v s="$1" '$1 != s { n++ } END { print n + 0 }'; }

# True for Wi-Fi connections: "IP:PORT" or Wireless debugging names like "adb-XXXX._adb-tls-connect._tcp".
gw_is_net() {
  case "$1" in
    *._adb-tls-connect._tcp* | *._adb._tcp*) return 0 ;;
    *:[0-9]*) return 0 ;;
  esac
  return 1
}

# "tcpip" for the classic port-5555 mode, "pair" for Android's Wireless debugging.
gw_mode() {
  local m
  if [ "$(gw_undo_get wifi_serial)" = "$1" ]; then
    m=$(gw_undo_get how)
    [ -n "$m" ] && { echo "$m"; return; }
  fi
  case "$1" in *:"$GW_PORT") echo tcpip ;; *) echo pair ;; esac
}

gw_how() { if gw_is_net "$1"; then echo "over Wi-Fi, $1"; else echo "over USB cable, serial $1"; fi; }

# Marketing name if the phone has one (Xiaomi often does), otherwise the model.
gw_name() {
  local n
  n=$(gw_sh "$1" 'getprop ro.product.marketname; getprop ro.product.model' | awk 'NF { print; exit }')
  echo "${n:-unknown model}"
}

# y/N question. Only y or yes counts; Enter, anything else or end of input means No.
gw_yes() {
  local a
  read -r -p "$1 [y/N] " a || return 1
  case "$a" in [Yy] | [Yy][Ee][Ss]) return 0 ;; esac
  return 1
}

# Ask for a value; prints it without spaces. Fails at end of input.
gw_ask() {
  local a
  read -r -p "$1" a || return 1
  printf '%s\n' "$a" | tr -d ' \t'
}

gw_valid_ip() {
  printf '%s\n' "$1" | awk -F . 'NR == 1 && NF == 4 {
      for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i + 0 > 255) exit 1
      ok = 1 }
    END { exit !ok }'
}

gw_valid_hostport() {
  local ip=${1%:*} port=${1##*:}
  [ "$ip" != "$1" ] || return 1
  gw_valid_ip "$ip" || return 1
  case "$port" in '' | *[!0-9]*) return 1 ;; esac
  [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# Accept "IP:PORT", or just "PORT" when we already know the IP ($2). Prints IP:PORT.
gw_fix_hostport() {
  local hp=$1
  case "$hp" in
    *[!0-9]*) ;;
    ?*) [ -n "${2:-}" ] && hp="$2:$hp" ;;
  esac
  gw_valid_hostport "$hp" || return 1
  echo "$hp"
}

# ---- undo file ($GW_UNDO) ----

gw_undo_get() { [ -f "$GW_UNDO" ] && sed -n "s/^$1=//p" "$GW_UNDO" | head -n 1; }

# gw_undo_save HOW USB_SERIAL WIFI_SERIAL OLD_TCP_PORT
gw_undo_save() {
  {
    echo "# Phone Pro: the phone was set up to work over Wi-Fi (Wi-Fi option in the menu)."
    if [ "$1" = pair ]; then
      echo "# Undo: choose the Wi-Fi option again and answer y to go back to USB. Then on the phone:"
      echo "#   Settings > Additional settings > Developer options > Wireless debugging: switch it off."
      echo "#   To forget this computer: Wireless debugging > Paired devices > this computer > Forget."
    else
      echo "# Undo: choose the Wi-Fi option again and answer y to go back to USB, or restart the phone."
      echo "# By hand, with the cable plugged in:  adb -s ${2:-<serial>} usb"
    fi
    echo "# old_tcp_port is what the phone reported before the change (empty = could not be read)."
    echo "date=$(date '+%Y-%m-%d %H:%M')"
    echo "how=$1"
    echo "usb_serial=$2"
    echo "wifi_serial=$3"
    echo "old_tcp_port=$4"
  } >"$GW_UNDO"
}

# ---- reading the phone ----

# The phone's Wi-Fi IPv4 address, or nothing. Tries `ip addr` first, then `ip route`.
gw_wifi_ip() {
  local ip
  ip=$(ash 'ip -f inet addr show wlan0' 2>/dev/null | awk '$1 == "inet" { sub(/\/.*/, "", $2); print $2; exit }')
  if ! gw_valid_ip "$ip"; then
    ip=$(ash 'ip route' 2>/dev/null | awk '
      { d = ""; s = ""
        for (i = 1; i < NF; i++) { if ($i == "dev") d = $(i + 1); if ($i == "src") s = $(i + 1) }
        if (s == "") next
        if (d == "wlan0") { if (w0 == "") w0 = s }
        else if (d ~ /^wlan/) { if (w == "") w = s } }
      END { if (w0 != "") print w0; else if (w != "") print w }')
  fi
  # 169.254.x.x means the Wi-Fi router never gave the phone an address.
  case "$ip" in 169.254.* | 0.*) return 1 ;; esac
  gw_valid_ip "$ip" && echo "$ip"
}

# Wait up to $2 seconds for device $1 to be ready.
gw_wait_device() {
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(gw_state "$1")" = device ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# adb connect with a few retries (adb connect exits 0 even when it fails, so read its words).
gw_connect() {
  local i=1 out
  gw_msg=""
  gw_told=0
  while [ "$i" -le 3 ]; do
    out=$(gw_adb connect "$1")
    if printf '%s\n' "$out" | grep -Eq '^(already )?connected to '; then return 0; fi
    gw_msg=$(printf '%s\n' "$out" | awk 'NF' | head -n 1)
    case "$out" in
      *authenticate*)
        if [ "$gw_told" = 0 ]; then
          echo "  Look at your phone: unlock it and tap \"Allow\" (tick \"Always allow\" first)."
          gw_told=1
        fi ;;
    esac
    [ "$i" -lt 3 ] && sleep 2
    i=$((i + 1))
  done
  return 1
}

# After connecting, wait until the phone accepts this computer (up to about 30 seconds).
gw_wait_ready() {
  local i=0
  while [ "$i" -lt 30 ]; do
    [ "$(gw_state "$1")" = device ] && return 0
    if [ "$gw_told" = 0 ] && [ "$(gw_dev_state "$1")" = unauthorized ]; then
      echo "  Look at your phone: unlock it and tap \"Allow\" (tick \"Always allow\" first)."
      gw_told=1
    fi
    sleep 1
    i=$((i + 1))
  done
  gw_msg="the phone did not accept the connection (state: $(gw_dev_state "$1"))"
  return 1
}

# The USB connection of the same phone as Wi-Fi connection $1 (empty if the cable is not plugged in).
gw_usb_twin() {
  local sn want s st n=0 only=""
  sn=$(gw_sh "$1" 'getprop ro.serialno')
  [ "$(gw_undo_get wifi_serial)" = "$1" ] && want=$(gw_undo_get usb_serial)
  while IFS="$GW_TAB" read -r s st <&3; do
    [ -n "$s" ] && [ "$st" = device ] || continue
    gw_is_net "$s" && continue
    n=$((n + 1))
    only=$s
    if [ -n "$sn" ]; then
      [ "$(gw_sh "$s" 'getprop ro.serialno')" = "$sn" ] && { echo "$s"; return 0; }
    elif [ -n "${want:-}" ] && [ "$s" = "$want" ]; then
      echo "$s"
      return 0
    fi
  done 3<<<"$(gw_devices)"
  # Wi-Fi side unreachable and nothing remembered: one phone on the cable is the best guess.
  if [ -z "$sn" ] && [ -z "${want:-}" ] && [ "$n" = 1 ]; then echo "$only"; fi
  return 0
}

# A working Wi-Fi connection of the same phone as USB device $1 (e.g. left over from earlier).
gw_net_twin() {
  local sn s st
  sn=$(gw_sh "$1" 'getprop ro.serialno')
  [ -n "$sn" ] || return 0
  while IFS="$GW_TAB" read -r s st <&3; do
    { [ "$st" = device ] && gw_is_net "$s"; } || continue
    [ "$(gw_sh "$s" 'getprop ro.serialno')" = "$sn" ] && { echo "$s"; return 0; }
  done 3<<<"$(gw_devices)"
  return 0
}

# ---- Android 11+ "Wireless debugging" (pairing code) ----

gw_pair_explain() {
  echo "Android 11 and newer (yours too) have their own Wi-Fi connection, called \"Wireless debugging\"."
  echo "It is encrypted, but needs a few taps on the phone:"
  echo "  1. Make sure the phone and this computer are on the same Wi-Fi."
  echo "  2. On the phone open Settings > Additional settings > Developer options."
  echo "  3. Turn on \"Wireless debugging\". If it asks \"Allow wireless debugging on this network?\","
  echo "     tap Allow (only on your own Wi-Fi)."
  echo "  4. Tap the words \"Wireless debugging\" (not the switch) to open its page."
  echo "  5. Tap \"Pair device with pairing code\". A box shows a 6-digit \"Wi-Fi pairing code\""
  echo "     and an \"IP address & Port\", for example 192.168.1.42:37123."
  echo "  6. Keep that box open and type both here when asked."
  echo "  7. Then look at the Wireless debugging page again. Its \"IP address & Port\" has a"
  echo "     DIFFERENT port number (for example 192.168.1.42:41567). Type that when asked."
  echo "  (By hand it is: adb pair IP:PORT CODE, then adb connect IP:PORT)"
  echo "  Wireless debugging switches itself off when the phone leaves this Wi-Fi or restarts."
}

# Explain, then offer to pair. $1 = phone IP if known, $2 = USB serial if known.
gw_pair_offer() {
  echo
  gw_pair_explain
  if gw_yes "Set up Wireless debugging now?"; then
    gw_pair_flow "${1:-}" "${2:-}"
    return
  fi
  echo "OK. To try it later, choose this option again."
  return 1
}

# Pair with a code, then connect. Returns 0 when connected (ANDROID_SERIAL is then set).
gw_pair_flow() {
  local hint=${1:-} usb=${2:-} ver major hp code out net tries=0
  ver=$(gw_adb version)
  major=$(printf '%s\n' "$ver" | awk '$1 == "Version" { split($2, v, "."); print v[1] + 0; exit }')
  if { [ -n "$major" ] && [ "$major" -lt 30 ]; } \
    || { [ -z "$major" ] && printf '%s\n' "$ver" | grep -Eq 'version 1\.0\.(3[0-9]|40)$'; }; then
    echo "Your adb is too old for Wireless debugging (it needs Platform-Tools version 30 or newer)."
    echo "Get the latest \"SDK Platform-Tools\" from developer.android.com/tools/releases/platform-tools"
    echo "and try again. Nothing was changed."
    return 1
  fi
  while :; do
    tries=$((tries + 1))
    hp=$(gw_ask "Pairing \"IP address & Port\" from the box (e.g. 192.168.1.42:37123), or Enter to stop: ") || hp=""
    if [ -z "$hp" ]; then echo "Stopped. Nothing was changed."; return 1; fi
    if ! hp=$(gw_fix_hostport "$hp" "$hint"); then
      echo "That does not look like an IP address and port (e.g. 192.168.1.42:37123). Nothing was changed."
      return 1
    fi
    code=$(gw_ask "6-digit \"Wi-Fi pairing code\" from the box: ") || code=""
    case "$code" in
      [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) echo "The code must be the 6 digits shown in the box. Nothing was changed."; return 1 ;;
    esac
    if ! gw_undo_save pair "$usb" "" "" 2>/dev/null; then
      echo "Could not save the undo file $GW_UNDO, so nothing was changed."
      return 1
    fi
    echo "Pairing with $hp ..."
    out=$(gw_adb pair "$hp" "$code")
    case "$out" in
      *"Successfully paired"*)
        echo "Paired. This computer is now on the phone's list of trusted computers."
        echo "(To remove it later: Developer options > Wireless debugging > Paired devices >"
        echo " this computer > Forget. This script cannot do that part for you.)"
        break ;;
      *"unknown command"*)
        rm -f "$GW_UNDO"
        echo "Your adb does not know \"pair\": it is too old. Get the latest \"SDK Platform-Tools\" from"
        echo "developer.android.com/tools/releases/platform-tools and try again. Nothing was changed."
        return 1 ;;
    esac
    rm -f "$GW_UNDO"
    echo "Pairing did not work. adb said: $(printf '%s\n' "$out" | awk 'NF' | head -n 1)"
    echo "Check the code (a new one appears each time the box opens) and keep the box open."
    if [ "$tries" -ge 3 ] || ! gw_yes "Try again with a new code?"; then
      echo "Nothing was changed."
      return 1
    fi
  done
  echo "Now look at the top of the \"Wireless debugging\" page on the phone: \"IP address & Port\"."
  net=$(gw_ask "Type that IP address & Port (or just the port number), or Enter to stop: ") || net=""
  if [ -z "$net" ]; then
    echo "Not connected. The pairing is kept, so next time only this connect step is needed."
    return 1
  fi
  if ! net=$(gw_fix_hostport "$net" "${hp%:*}"); then
    echo "That does not look like an IP address and port (e.g. 192.168.1.42:41567). Not connected."
    return 1
  fi
  gw_undo_save pair "$usb" "$net" "" 2>/dev/null
  echo "Connecting to $net ..."
  if gw_connect "$net" && gw_wait_ready "$net"; then
    export ANDROID_SERIAL="$net"
    echo "Done: connected over Wi-Fi to $(gw_name "$net") at $net."
    echo "You can unplug the USB cable. Every option in this menu now works over Wi-Fi."
    return 0
  fi
  echo "Could not connect. adb said: ${gw_msg:-no answer}"
  echo "Check that you typed the port from the top of the Wireless debugging page (not the pairing one)."
  return 1
}

# ---- switching ----

# Offer to put the phone back in USB-only mode after a failed Wi-Fi attempt.
gw_undo_tcpip_now() {
  local out
  echo "The phone is still listening for Wi-Fi connections until it restarts."
  if gw_yes "Switch it back to USB-only mode now? (recommended)"; then
    out=$(gw_adb -s "$1" usb)
    if printf '%s\n' "$out" | grep -q 'restarting in USB mode'; then
      sleep 2
      gw_wait_device "$1" 20
      rm -f "$GW_UNDO"
      echo "Done: the phone is back in USB-only mode."
    else
      echo "The phone did not confirm (it said: ${out:-nothing}). Restarting the phone also switches it back."
    fi
  else
    echo "Left as is. Restarting the phone switches it back to USB-only mode."
  fi
}

# USB -> Wi-Fi with `adb tcpip`. $1 = USB serial of the phone.
gw_go_wifi() {
  local usb=$1 ip net old new out
  echo "This lets every option in this menu reach your phone over Wi-Fi, so you can unplug the cable."
  ip=$(gw_wifi_ip)
  if [ -z "$ip" ]; then
    echo "Could not find your phone's Wi-Fi address."
    echo "Most likely the phone is not connected to Wi-Fi. Connect it to the same Wi-Fi as this"
    echo "computer (Settings > Wi-Fi), then choose this option again."
    echo "If it IS on Wi-Fi, you can type the address yourself: on the phone open Settings > Wi-Fi,"
    echo "tap your Wi-Fi name and look for \"IP address\" (four numbers, e.g. 192.168.1.42)."
    ip=$(gw_ask "Phone's IP address, or Enter to stop: ") || ip=""
    if [ -z "$ip" ]; then echo "Stopped. Nothing was changed."; return 0; fi
    if ! gw_valid_ip "$ip"; then
      echo "'$ip' does not look like an IP address (four numbers with dots, e.g. 192.168.1.42)."
      echo "Nothing was changed."
      return 0
    fi
  fi
  net="$ip:$GW_PORT"
  echo "Your phone's Wi-Fi address: $ip"
  echo
  echo "Please read before you say yes:"
  echo "  - Only do this on Wi-Fi you trust, like your home Wi-Fi. Not on cafe, hotel, airport,"
  echo "    school or other public Wi-Fi."
  echo "  - While it is on, the phone accepts debugging connections over this Wi-Fi. Only computers"
  echo "    you already allowed get in. This computer is recognised by its \"adb key\" (a small"
  echo "    secret file adb keeps here, remembered when you tapped Allow). Any other computer makes"
  echo "    the phone ask \"Allow USB debugging?\" - tap Cancel if you did not start it yourself."
  echo "  - This classic Wi-Fi link is not encrypted: one more reason to use only trusted Wi-Fi."
  echo "  - Nothing is installed and none of your settings or data change. Calls, SMS, notifications"
  echo "    and banking apps are not affected. It switches off when the phone restarts, or when you"
  echo "    choose this option again and go back to USB."
  echo "  - This computer must be on the same Wi-Fi (or the same home network) as the phone."
  if ! gw_yes "Switch to Wi-Fi now?"; then
    echo "OK, nothing was changed."
    return 0
  fi
  old=$(ash 'getprop service.adb.tcp.port' 2>/dev/null | head -n 1)
  if ! gw_undo_save tcpip "$usb" "$net" "$old" 2>/dev/null; then
    echo "Could not save the undo file $GW_UNDO, so nothing was changed."
    return 0
  fi
  echo "Switching the phone to Wi-Fi mode (its debugging service restarts, a few seconds)..."
  out=$(gw_adb -s "$usb" tcpip "$GW_PORT")
  if ! printf '%s\n' "$out" | grep -q 'restarting in TCP mode'; then
    rm -f "$GW_UNDO"
    echo "The phone refused to switch to Wi-Fi mode. It said: ${out:-nothing}"
    echo "Nothing was changed on the phone. Some MIUI versions block this classic way."
    gw_wait_device "$usb" 10
    gw_pair_offer "$ip" "$usb"
    return 0
  fi
  sleep 2
  gw_wait_device "$usb" 20 || echo "  (the phone has not come back on the cable yet; trying Wi-Fi anyway)"
  echo "Connecting to $net ..."
  if ! gw_connect "$net"; then
    echo "Could not connect over Wi-Fi. adb said: ${gw_msg:-no answer}"
    echo "Common reasons:"
    echo "  - This computer is on a different network (another router, mobile hotspot, or a VPN is on)."
    echo "  - Guest Wi-Fi or \"AP isolation\" stops devices on the same Wi-Fi from seeing each other."
    echo "  - A firewall on this computer blocks adb."
    echo "  - Some MIUI versions block this classic Wi-Fi mode."
    gw_undo_tcpip_now "$usb"
    gw_pair_offer "$ip" "$usb"
    return 0
  fi
  if ! gw_wait_ready "$net"; then
    echo "Connected, but $gw_msg."
    gw_adb disconnect "$net" >/dev/null
    gw_undo_tcpip_now "$usb"
    return 0
  fi
  export ANDROID_SERIAL="$net"
  echo "Done: connected over Wi-Fi to $(gw_name "$net") at $net."
  new=$(ash 'getprop service.adb.tcp.port' 2>/dev/null | head -n 1)
  [ "$new" = "$GW_PORT" ] && echo "Checked: the phone reports it is listening on Wi-Fi port $GW_PORT."
  echo "You can unplug the USB cable now. Every option in this menu now works over Wi-Fi."
  echo "It lasts until the phone restarts. To go back to the cable, choose this option again."
  echo "(Big copies such as the photo backup are faster with the cable.)"
  echo "Undo details saved in $GW_UNDO."
}

# Wi-Fi -> USB. $1 = the Wi-Fi connection (IP:PORT or Wireless debugging name).
gw_back_to_usb() {
  local net=$1 how usb alive out ok=1 port
  how=$(gw_mode "$net")
  alive=no
  [ "$(gw_state "$net")" = device ] && alive=yes
  usb=$(gw_usb_twin "$net")
  if [ -z "$usb" ] && [ "$alive" = yes ]; then
    echo "The USB cable is not plugged in (or the phone is not showing up on it)."
    echo "If you go on, this script cannot reach the phone until you plug the cable in."
    if [ "$how" = pair ]; then
      gw_yes "Disconnect from Wi-Fi anyway?" || { echo "OK, nothing was changed. You are still connected over Wi-Fi."; return 0; }
    else
      gw_yes "Switch the phone off Wi-Fi mode anyway?" || { echo "OK, nothing was changed. You are still connected over Wi-Fi."; return 0; }
    fi
  fi
  if [ "$how" = pair ]; then
    gw_adb disconnect "$net" >/dev/null
    echo "Disconnected from $net."
    echo "To turn Wireless debugging off completely: on the phone open Settings > Additional settings >"
    echo "Developer options and switch off \"Wireless debugging\" (it also switches itself off when the"
    echo "phone leaves this Wi-Fi or restarts)."
  elif [ -n "$usb" ]; then
    echo "Switching the phone back to USB-only mode..."
    gw_adb disconnect "$net" >/dev/null
    out=$(gw_adb -s "$usb" usb)
    if printf '%s\n' "$out" | grep -q 'restarting in USB mode'; then
      sleep 2
      gw_wait_device "$usb" 20 || echo "  (the phone is taking a while to come back on the cable)"
    else
      ok=0
      echo "The phone did not confirm (it said: ${out:-nothing}). It goes back to USB-only mode by itself when it restarts."
    fi
  elif [ "$alive" = yes ]; then
    out=$(gw_adb -s "$net" usb)
    if printf '%s\n' "$out" | grep -q 'restarting in USB mode'; then
      echo "The phone is back in USB-only mode."
    else
      ok=0
      echo "The phone did not confirm (it said: ${out:-nothing}). Restarting the phone also switches it off."
    fi
    gw_adb disconnect "$net" >/dev/null
  else
    gw_adb disconnect "$net" >/dev/null
    ok=0
    echo "The phone cannot be reached over Wi-Fi or the cable right now, so it may still be listening"
    echo "on Wi-Fi. That stops by itself when the phone restarts, or plug in the cable and choose this"
    echo "option again."
  fi
  # Read back what happened, then choose which connection the rest of the script uses.
  if [ "$(gw_dev_state "$net")" = device ]; then
    ok=0
    echo "Note: $net still shows as connected."
  fi
  if [ -n "$usb" ]; then
    if [ "$(gw_others "$usb")" -gt 0 ]; then export ANDROID_SERIAL="$usb"; else unset ANDROID_SERIAL; fi
    if [ "$(gw_state "$usb")" = device ]; then
      if [ "$how" = tcpip ]; then
        port=$(gw_sh "$usb" 'getprop service.adb.tcp.port')
        case "$port" in
          [1-9]*) ok=0; echo "Warning: the phone still reports Wi-Fi port $port. Restarting the phone switches it off." ;;
          0) echo "Checked: the phone is no longer listening on Wi-Fi." ;;
        esac
      fi
      echo "Back on the USB cable: $(gw_name "$usb"). Keep the cable plugged in."
    else
      echo "The phone has not come back on the cable yet. Unplug it, plug it back in and unlock the phone."
    fi
  else
    unset ANDROID_SERIAL
    echo "Plug the USB cable in before you choose another option."
  fi
  if [ "$ok" = 1 ]; then rm -f "$GW_UNDO"; elif [ -f "$GW_UNDO" ]; then echo "Undo details kept in $GW_UNDO."; fi
  return 0
}

gw_already_wifi() {
  echo "You are connected over Wi-Fi right now: $(gw_name "$1") at $1."
  echo "Every option works without the cable until the phone restarts."
  if gw_yes "Switch back to the USB cable?"; then
    gw_back_to_usb "$1"
  else
    echo "OK, staying on Wi-Fi. Nothing was changed."
  fi
}

gw_lost() {
  local net=$1 st
  st=$(gw_dev_state "$net")
  echo "The Wi-Fi connection to the phone ($net) is not working right now (adb says: ${st:-not connected})."
  echo "This happens when the phone restarts, moves to another Wi-Fi, or is out of range."
  if gw_yes "Try to reconnect over Wi-Fi?"; then
    echo "Reconnecting to $net ..."
    gw_adb disconnect "$net" >/dev/null
    if gw_connect "$net" && gw_wait_ready "$net"; then
      export ANDROID_SERIAL="$net"
      echo "Reconnected. Every option works over Wi-Fi again."
      return 0
    fi
    echo "Could not reconnect. adb said: ${gw_msg:-no answer}"
    echo "(After a restart the phone is back in USB-only mode, so plug in the cable to switch again.)"
  fi
  if gw_yes "Switch this script back to the USB cable?"; then
    gw_back_to_usb "$net"
  else
    echo "OK, nothing was changed."
  fi
}

# ---- menu entry ----

go_wireless() {
  local cur net
  echo "== Use the phone over Wi-Fi (no cable) =="
  cur=${ANDROID_SERIAL:-}
  if [ -z "$cur" ]; then
    cur=$(adb get-serialno </dev/null 2>/dev/null | tr -d '\r' | head -n 1)
    if [ -z "$cur" ] || [ "$cur" = unknown ]; then
      gw_pick_device || { echo "Nothing was changed."; return 0; }
      cur=${ANDROID_SERIAL:-}
    fi
  fi
  if gw_is_net "$cur"; then
    if [ "$(gw_state "$cur")" = device ]; then gw_already_wifi "$cur"; else gw_lost "$cur"; fi
    return 0
  fi
  if [ "$(gw_state "$cur")" != device ]; then
    echo "The phone ($cur) is not ready: $(gw_advice "$(gw_dev_state "$cur")" "$cur")"
    echo "Nothing was changed."
    return 0
  fi
  net=$(gw_net_twin "$cur")
  if [ -n "$net" ]; then
    echo "Your phone is already connected over Wi-Fi too ($net), probably from earlier."
    if gw_yes "Use Wi-Fi from now on (so you can unplug the cable)?"; then
      export ANDROID_SERIAL="$net"
      echo "Done: every option now works over Wi-Fi. You can unplug the cable."
      return 0
    fi
    if gw_yes "Turn that Wi-Fi connection off and stay on the USB cable?"; then
      gw_back_to_usb "$net"
    else
      echo "OK, nothing was changed."
    fi
    return 0
  fi
  gw_go_wifi "$cur"
}

# ---- startup check ----

# Plain-English advice for a device that is listed but not ready. $1 = state, $2 = serial.
gw_advice() {
  case "$1" in
    unauthorized)
      echo "waiting for your OK. Unlock the phone and tap \"Allow\" on the \"Allow USB debugging?\""
      echo "     prompt (tick \"Always allow from this computer\"). No prompt? Unplug and plug the cable back in." ;;
    authorizing)
      echo "still checking this computer. Unlock the phone and wait a few seconds." ;;
    offline)
      if gw_is_net "$2"; then
        echo "the Wi-Fi connection has dropped (the phone restarted, changed Wi-Fi, or is out of range)."
      else
        echo "connected but not answering. Unplug the cable and plug it back in. If that does not help,"
        echo "     turn \"USB debugging\" off and on again in Developer options."
      fi ;;
    "no permissions"*)
      echo "this computer is not allowed to use the phone's USB connection (common on Linux)."
      echo "     Set up the USB rules from developer.android.com/studio/run/device, then try again." ;;
    recovery | rescue | sideload)
      echo "the phone is in recovery mode. Restart it normally." ;;
    bootloader)
      echo "the phone is in fastboot (bootloader) mode. Hold the power button to restart it normally." ;;
    "")
      echo "not connected." ;;
    *)
      echo "not ready yet (adb says: $1). Wait a few seconds." ;;
  esac
}

# Print every listed device that is not ready, with advice. $1 = list from gw_devices.
gw_list_bad() {
  local s st
  while IFS="$GW_TAB" read -r s st <&3; do
    [ -n "$s" ] && [ "$st" != device ] || continue
    echo "  $s: $(gw_advice "$st" "$s")"
  done 3<<<"$1"
}

# Same, with a heading, but only when there is something to show.
gw_list_unused() {
  printf '%s\n' "$1" | awk -F '\t' 'NF && $2 != "device" { f = 1 } END { exit !f }' || return 0
  echo "Also connected, but not used:"
  gw_list_bad "$1"
}

# Several ready devices: list them with names and let the user choose. $1 = ready serials.
gw_choose() {
  local s n=0 sn name pick tries=0 seen="" same picked=""
  echo "More than one device is connected. Which one should this script use?"
  while read -r s <&3; do
    [ -n "$s" ] || continue
    n=$((n + 1))
    name=$(gw_name "$s")
    sn=$(gw_sh "$s" 'getprop ro.serialno')
    same=""
    if [ -n "$sn" ]; then
      same=$(printf '%s' "$seen" | awk -v k="$sn" '$1 == k { print "   (same phone as " $2 ")"; exit }')
      seen="$seen$sn $n
"
    fi
    printf '  %d) %-22s %s%s\n' "$n" "$name" "$(gw_how "$s")" "$same"
  done 3<<<"$1"
  while :; do
    pick=$(gw_ask "Type its number and press Enter [1]: ") || { echo "No device chosen."; return 1; }
    [ -n "$pick" ] || pick=1
    case "$pick" in
      *[!0-9]*) ;;
      *) if [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then break; fi ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then echo "No device chosen."; return 1; fi
    echo "Please type a number from 1 to $n."
  done
  picked=$(printf '%s\n' "$1" | awk 'NF' | sed -n "${pick}p")
  export ANDROID_SERIAL="$picked"
  echo "Using: $(gw_name "$picked") ($(gw_how "$picked"))."
  return 0
}

# Replacement for the main script's startup check. Returns 0 with ANDROID_SERIAL exported,
# or 1 (the caller then exits) when no usable device is found.
gw_pick_device() {
  local want=${ANDROID_SERIAL:-} list ready n round=0 a prev=""
  if [ -n "$want" ] && [ -z "$(gw_dev_state "$want")" ] && gw_is_net "$want"; then
    case "$want" in
      *._tcp*) ;;
      *) gw_adb connect "$want" >/dev/null; sleep 1 ;;
    esac
  fi
  while :; do
    list=$(gw_devices)
    if [ -n "$want" ]; then
      list=$(printf '%s\n' "$list" | awk -F '\t' -v s="$want" '$1 == s')
    fi
    ready=$(printf '%s\n' "$list" | awk -F '\t' '$2 == "device" { print $1 }')
    n=$(printf '%s\n' "$ready" | awk 'NF { n++ } END { print n + 0 }')
    if [ "$n" -ge 2 ]; then
      gw_choose "$ready" || return 1
      gw_list_unused "$list"
      return 0
    fi
    if [ "$n" = 1 ]; then
      export ANDROID_SERIAL="$ready"
      if [ -n "$want" ]; then
        echo "Using the device set in ANDROID_SERIAL: $(gw_name "$ready") ($(gw_how "$ready"))."
      else
        echo "Phone found: $(gw_name "$ready") ($(gw_how "$ready"))."
      fi
      gw_list_unused "$list"
      return 0
    fi
    if [ -z "$list" ]; then
      if [ -n "$want" ]; then
        echo "ANDROID_SERIAL is set to '$want', but no device with that name is connected."
        echo "Plug it in (check the name with 'adb devices'), or run 'unset ANDROID_SERIAL'"
        echo "and start this script again to choose from what is connected."
        return 1
      fi
      echo "No phone found. Check the cable, unlock the phone, and accept the 'Allow USB debugging' prompt."
      adb devices </dev/null 2>&1 | tr -d '\r'
      echo "No cable? Android 11+ phones can also connect over Wi-Fi (\"Wireless debugging\")."
      if gw_yes "Show how and connect over Wi-Fi now?"; then
        echo
        gw_pair_explain
        gw_pair_flow "" "" && return 0
      fi
      return 1
    fi
    if [ "$list" = "$prev" ]; then
      echo "Still not ready."
    else
      echo "Found a device, but it is not ready:"
      gw_list_bad "$list"
    fi
    prev=$list
    round=$((round + 1))
    if [ "$round" -gt 5 ]; then
      echo "Fix that on the phone, then start this script again."
      return 1
    fi
    a=$(gw_ask "Fix that on the phone, then press Enter to check again (or type q to quit): ") || return 1
    case "$a" in q | Q) return 1 ;; esac
  done
}
