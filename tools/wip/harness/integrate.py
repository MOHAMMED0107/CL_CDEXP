"""Assemble the final phone-pro.sh from the main script and the finished features.
Usage: integrate.py <scratchpad> <feature-key> [<feature-key> ...]   (only keys that passed review/tests)"""
import sys, pathlib
S = pathlib.Path(sys.argv[1])
include = sys.argv[2:]
ALL = [  # key, entry function, section, menu text
    ("free-space",      "free_space",      "Top picks",  "Free up space: clear app caches, see what fills the phone, remove junk"),
    ("battery-drain",   "battery_drain",   "Top picks",  "Battery drain detective: which apps drain the battery, and why"),
    ("stolen-ready",    "stolen_ready",    "Top picks",  "Lost-or-stolen check (score out of 8) + emergency card with IMEI"),
    ("scam-shield",     "scam_shield",     "Top picks",  "OTP & SIM scam shield: hide OTPs on lock screen, check call forwarding"),
    ("go-wireless",     "go_wireless",     "Top picks",  "Go wireless: use this script over Wi-Fi, no cable (or back to USB)"),
    ("eol-security",    "eol_security",    "More tools", "Security check-up for an old phone (patch age, Chrome/WebView, risks)"),
    ("spy-scan",        "spy_scan",        "More tools", "Scam & spy app scan: screen-overlay apps, hidden apps, fake APK files"),
    ("bg-manager",      "bg_manager",      "More tools", "Background app manager: put battery hogs to sleep, fix late messages"),
    ("tune-up",         "tune_up",         "More tools", "Why is my phone slow? Check-up + tune-up"),
    ("photo-sync",      "photo_sync",      "More tools", "Smart photo sync to this computer (only new files) + free space"),
    ("reset-kit",       "reset_kit",       "More tools", "Contacts safety copy + factory-reset / new-phone kit"),
    ("handoff",         "handoff",         "More tools", "Phone <-> PC: screenshots, recordings, links, text, files, webcam"),
    ("screen-lab",      "screen_lab",      "More tools", "Screen comfort: display size, bold text, status bar, extra dim"),
    ("hidden-features", "hidden_features", "More tools", "Unlock hidden features: notification history, IR remote, MIUI tour"),
    ("charger-test",    "charger_test",    "More tools", "Charger & cable tester: is fast charging really working?"),
]
feats = [f for f in ALL if f[0] in include]
missing = [k for k in include if k not in [f[0] for f in ALL]]
assert not missing, f"unknown keys {missing}"
main = (S / "phone-pro.sh").read_text()

START = '''if ! adb get-state >/dev/null 2>&1; then
  echo "No phone found. Check the cable, unlock the phone, and accept the 'Allow USB debugging' prompt."
  adb devices
  exit 1
fi

'''
have_gw = any(f[0] == "go-wireless" for f in feats)
if have_gw:
    assert main.count(START) == 1, "startup block not found"
    main = main.replace(START, "")

blocks = []
for key, fn, _, _ in feats:
    src = (S / "features" / key / "feature.sh").read_text().rstrip() + "\n"
    assert f"{fn}()" in src or f"{fn} ()" in src, f"{fn} missing in {key}"
    blocks.append(f"# ---------- {key} ----------\n{src}\n")
startup = "# ==== startup ====\n" + ("gw_pick_device || exit 1\n\n" if have_gw else "\n")
LOOP = "while true; do\n"
assert main.count(LOOP) == 1
main = main.replace(LOOP, "".join(blocks) + startup + LOOP)

# Menu: section headers, numbers 14+ for included features, lock-up quit if available.
OLD_HEAD = "==== Phone Pro ====\n 1) Health report"
assert main.count(OLD_HEAD) == 1
main = main.replace(OLD_HEAD, "==== Phone Pro ====\n  -- Basics --\n 1) Health report")
lines, section, n = [], None, 14
case = []
for key, fn, sec, text in feats:
    if sec != section:
        lines.append(f"  -- {sec} --\n")
        section = sec
    lines.append(f"{n}) {text}\n")
    case.append(f"    {n}) {fn} ;;\n")
    n += 1
have_lockup = any(f[0] == "eol-security" for f in feats)
OLD_MENU_END = "13) Battery health log (saves a record each time, so you can see the trend)\n q) Quit\n"
assert main.count(OLD_MENU_END) == 1
quit_lines = " q) Quit\n" + (" x) Quit and turn off USB debugging (recommended when you're done)\n" if have_lockup else "")
main = main.replace(OLD_MENU_END, OLD_MENU_END.replace(" q) Quit\n", "") + "".join(lines) + quit_lines)
OLD_CASE_END = "    13) battery_log ;;\n"
assert main.count(OLD_CASE_END) == 1
main = main.replace(OLD_CASE_END, OLD_CASE_END + "".join(case))
if have_lockup:
    OLD_Q = "    q|Q) exit 0 ;;\n"
    assert main.count(OLD_Q) == 1
    main = main.replace(OLD_Q, OLD_Q + "    x|X) es_lockup && exit 0 ;;\n")
(S / "phone-pro.sh").write_text(main)
print("integrated:", ", ".join(f"{14+i}={f[0]}" for i, f in enumerate(feats)))
