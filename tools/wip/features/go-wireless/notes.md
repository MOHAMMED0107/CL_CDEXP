# go-wireless

## Menu line

```
Go wireless: use this script over Wi-Fi, no cable (or back to USB)
```

(Matches the text in `harness/integrate.py`. Entry function: `go_wireless`.)

## What it does (for the user)

- Plug the phone in once, choose this option and answer **y**. The phone switches to Wi-Fi
  mode, the script connects to it over your Wi-Fi, and you can unplug the cable. Every
  other option then works without the cable.
- It lasts until the phone restarts. Choose the option again to go back to the USB cable.
- Before anything happens it explains the safety side in plain words. Use it only on Wi-Fi
  you trust. The phone still only lets in computers you already allowed. The classic Wi-Fi
  link is not encrypted.
- If MIUI blocks the classic way, it explains Android's own **Wireless debugging** step by
  step, and can do the pairing (`adb pair`) and connecting (`adb connect`) with the values you type.
- At start-up the script now copes with no phone, a phone waiting for "Allow", an offline
  phone, or several devices (for example the same phone on cable and Wi-Fi, or two phones).
  It lists them by name and lets you choose.

## How the main script calls it (startup check)

`gw_pick_device` replaces the current startup check:

```bash
if ! adb get-state >/dev/null 2>&1; then
  echo "No phone found. Check the cable, unlock the phone, and accept the 'Allow USB debugging' prompt."
  adb devices
  exit 1
fi
```

Replace that whole block with this one line, placed **after** feature.sh's definitions:

```bash
gw_pick_device || exit 1
```

`harness/integrate.py` already does exactly this. It deletes the block above, pastes the
feature blocks before the menu loop, then writes `# ==== startup ====` and
`gw_pick_device || exit 1`. The tests run the real integrate.py on a private copy and drive
the real menu (pick a phone, then 14 for Wi-Fi, 1 for health over Wi-Fi, 14 again for USB,
1 for health over USB).

- `gw_pick_device` returns 0 after exporting `ANDROID_SERIAL` (the device chosen). It returns
  1 when no usable device is found, and the caller exits as before.
- It never uses `ash` or `TMPD`, only plain `adb`. So it also works if feature.sh is pasted
  right after `need adb`, before those helpers exist. A test covers that placement too.
- If you already set `ANDROID_SERIAL`, it is respected and you are not asked anything. If
  that device is missing, the script says so and exits instead of quietly using another
  phone. If it is an `IP:PORT`, the script tries `adb connect` once first.
- Nothing else in the main script has to change. adb reads `ANDROID_SERIAL` whenever `-s`
  is not given, so every existing `adb`/`ash` call (and `adb pull`) follows it, and so does
  scrcpy (option 8). `go_wireless` exports/unsets it in the main shell (it is never run in
  a subshell), so the change takes effect for every later menu option.

Startup cases:

| `adb devices` shows | What happens |
|---|---|
| nothing | The old message plus the raw `adb devices` output, as before. It also offers Wireless debugging pairing for people with no cable; Enter means no, and the script exits 1. |
| 1 device | It is picked silently, with one line: `Phone found: Redmi Note 9 Pro (over USB cable, serial ...)`. |
| 1 ready + others not ready | The ready one is used, and the others are listed with advice. |
| only unauthorized / offline / authorizing / no permissions / recovery / bootloader | Plain-English advice for each, then "press Enter to check again" (up to 5 times, or q). Returns 1 at the end. |
| 2+ ready | A numbered list with names (`ro.product.marketname`, else `ro.product.model`) and how each is connected. The same phone on cable and Wi-Fi is marked "(same phone as 1)", using `ro.serialno`. Enter picks 1, and end of input picks nothing (returns 1). |

## Commands it sends (all work as the adb shell user on Android 12 / MIUI 14, no root)

- On the phone: `ip -f inet addr show wlan0`, then `ip route` as a fallback (keeps
  `src` of `dev wlan*` routes, as scrcpy does). Also `getprop ro.product.marketname`,
  `getprop ro.product.model`, `getprop ro.serialno` and `getprop service.adb.tcp.port`.
  The last one is only best-effort: it is `adbd_config_prop` and some builds hide it from
  the shell. When it is empty, the script does not claim anything.
- On the computer: `adb devices`, `adb -s X get-state`, `adb get-serialno`,
  `adb -s <usb> tcpip 5555`, `adb connect IP:5555`, `adb -s <usb> usb` (or
  `adb -s IP:5555 usb` when there is no cable), `adb disconnect IP:PORT`, `adb version`,
  `adb pair IP:PORT CODE`.
- Waiting for adbd to restart after `tcpip` uses `sleep 2` plus `get-state` polling
  (20 x 1 s), with no `timeout` or `wait-for-device`. `adb connect` always exits 0, so
  success is read from its words (`connected to` / `already connected to`). It retries
  3 times.

## Undo

- Before any change, `$HOME/phone-pro-wifi-undo.txt` saves `how` (tcpip or pair), the
  USB serial, the Wi-Fi address and the phone's old `service.adb.tcp.port` when readable.
- Undo = choose the option again, then **y** to "Switch back to the USB cable?". That runs
  `adb disconnect IP:5555` and `adb -s <usb serial> usb` (the phone goes back to USB-only
  mode). It reads the result back (USB device ready, Wi-Fi connection gone, port 0 if
  readable) and unsets `ANDROID_SERIAL`. If another device is still attached, it sets
  `ANDROID_SERIAL` to the cable connection instead, so plain adb calls stay unambiguous.
  The undo file is deleted on success.
- Restarting the phone also undoes Wi-Fi mode.
- If the Wi-Fi connection fails after `tcpip`, the script offers to put the phone back in
  USB-only mode right away (Enter = leave it, it ends at the next restart).
- Wireless debugging pairing **cannot be undone by the script**, and it says so. To remove
  it on the phone: Developer options > Wireless debugging > Paired devices > this computer
  > Forget. "Back to USB" only disconnects in that mode and tells the user how to switch
  Wireless debugging off.
- If the script is restarted while the phone is still on Wi-Fi, the option finds the
  leftover Wi-Fi connection of the same phone. It offers to use it, or to turn it off.
  A dropped connection (phone restarted, other Wi-Fi) offers reconnect, then back to USB.

## Limitations

- Classic Wi-Fi mode (`adb tcpip`) ends when the phone restarts (Android 11+ does not keep
  it), and the link is not encrypted. Trusted Wi-Fi only.
- The phone and computer must reach each other. Guest Wi-Fi / "AP isolation", a VPN, a
  firewall, or a computer on another network will make `adb connect` fail. The script
  lists these reasons.
- Some MIUI builds may refuse or ignore `adb tcpip`. The fallback (Wireless debugging)
  needs Platform-Tools 30+ (checked with `adb version`). The user has to read the pairing
  code and the two different ports off the phone. Wireless debugging switches itself off
  when the phone leaves that Wi-Fi.
- Only IPv4 on `wlan*` is detected. A `169.254.x.x` address counts as "not on Wi-Fi". If the
  address cannot be read, the user can type it (validated) or press Enter to stop.
- `ANDROID_SERIAL` lives only while the script runs. After quitting and restarting with the
  cable still in, `gw_pick_device` lists both connections (marked as the same phone).
- If the Wi-Fi drops in the middle of a session, other options print adb errors until the
  user chooses this option again (reconnect or back to USB).
- Big transfers (backup, mirroring) are slower over Wi-Fi. The script mentions it.
- With 2+ ready devices at startup, Enter picks number 1 (a choice of device, not a change).
- Tests use a fake adb modelled on AOSP adb messages. They were not run on a real phone or
  on a real bash 3.2 / BWK awk: the code was kept to bash 3.2 / POSIX awk by review plus
  automated checks, and the tests ran on bash 5.2 + mawk.

## Tests

`bash test/run-tests.sh` covers 58 groups and about 196 checks. They cover the happy path,
Enter to everything, end of input, not on Wi-Fi, unreadable data, tcpip refused, pairing
(ok, wrong code + retry, bad code, old adb, mDNS auto-connect), connect refused / Windows
10060, the phone asking for Allow, back to USB with and without a cable, a lost connection,
a leftover Wi-Fi connection, Wireless debugging disconnect, and every `adb devices` state.
They also run integrate.py end to end and include static checks (no top-level commands,
gw_ prefixes, bash 3.2 / portable awk / no GNU-only tools, fd-3 read loops, `</dev/null`
on every adb call). Shellcheck runs too when it is installed, or when
`SHELLCHECK=/path/to/shellcheck` is set.
