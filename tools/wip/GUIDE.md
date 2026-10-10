# Phone Pro — Easy User Guide

A friendly guide for your **Xiaomi Redmi Note 9 Pro** (MIUI 14, Android 12).
No technical knowledge needed. Just follow the steps in order.

> Your phone does **not** need to be rooted. You only plug it into your computer
> with a USB cable and run one program. The program talks to your phone using
> Google's official tool called **ADB** (Android Debug Bridge).

---

## 1. What is Phone Pro?

Phone Pro is a simple **menu program**. You run it on your **computer**, with your
**phone connected by USB cable**. It shows a list of numbered options. You type a
number, press Enter, and it does that one job. Then you can pick another, or quit.

### What it can do
- Show a **health report** (battery, storage, Android/MIUI version).
- Make the phone **feel faster** (smaller animations).
- **Block ads** in every app and browser (using Private DNS).
- **Remove Xiaomi/MIUI ads and junk apps** — and put them all back if you change your mind.
- **Back up** your photos, documents and downloads to the computer.
- **Mirror and control** the phone from your computer (optional extra tool).
- **Privacy audit**: see which apps can read your SMS, contacts, location, mic and camera.
- **Find apps you never use** and how much space they waste.
- Keep a **battery health log** so you can watch your battery age over time.
- More tools are being added as options **14 and up** (see section 5).

### What it will NOT do
- **It never needs root.** Your warranty and your phone stay normal.
- **It cannot break your phone.** It only uses safe, standard commands. It does not
  touch Android system files, it does not "flash" anything, and it cannot brick the phone.
- **Every change it makes can be undone.** Speed, ads/DNS and removed apps all have an
  "undo" option right in the menu (see the table in section 4).
- It does **not** delete your photos or personal files. (It *copies* them for backup.)

### One honest warning
A few options can **uninstall apps** if you say "yes" when it asks you.
Uninstalling an app also deletes **that app's own data**. You can always reinstall the
app, but anything saved only inside it may be gone. The guide points this out each time
it matters. When in doubt, just press **Enter** (that means **No**).

---

## 2. One-Time Setup

Do this once. It takes about 10 minutes. There are two parts:
**(A)** get your phone ready, and **(B)** get your computer ready.

### A. Get the phone ready (MIUI 14)

**Step 1 — Unlock "Developer options" (the hidden menu)**
1. Open **Settings**.
2. Go to **About phone**.
3. Find **MIUI version** and **tap it 7 times** quickly.
4. You will see a message like *"You are now a developer!"*

**Step 2 — Turn on USB debugging**
1. Open **Settings** -> **Additional settings** -> **Developer options**.
   (On MIUI it lives *inside* "Additional settings".)
2. Turn **ON**: **USB debugging**.
   - This one is needed for **everything**.

**Step 3 — Turn on "USB debugging (Security settings)"** *(needed for options 2–5)*
1. In the same **Developer options** screen, turn **ON**:
   **USB debugging (Security settings)**.
2. MIUI will ask you to be signed in to a **Mi account** and to have a **SIM card
   inserted** before it lets you turn this on. Turning on **mobile data** for a moment
   also helps it go through.
   - This toggle is what lets the tool change settings like **animation speed** and
     **ad-blocking DNS** (menu options 2, 3, 4, 5). Without it, those options will say
     *"Could not change..."* — see Troubleshooting.

> Tip: Keep the phone **unlocked** while you use Phone Pro.

### B. Get the computer ready

You need **ADB** (also called "Android platform-tools"). Pick your computer type:

#### Windows
1. **Download the official platform-tools:**
   <https://developer.android.com/tools/releases/platform-tools>
   Click **"Download Android SDK Platform-Tools for Windows"** and accept the terms.
   (This is Google's official page. It includes `adb`.)
2. **Unzip** the downloaded file. You get a folder called **platform-tools**.
   Put it somewhere easy, for example `C:\platform-tools`.
3. **Make the computer find `adb`.** Either:
   - **Easiest:** copy the `phone-pro.sh` file *into* the `platform-tools` folder and
     run it from there, **or**
   - **Add to PATH** (so `adb` works from any folder): Windows **Settings** ->
     search "environment variables" -> **Edit the system environment variables** ->
     **Environment Variables** -> under **Path** click **Edit** -> **New** -> paste the
     full folder path (e.g. `C:\platform-tools`) -> **OK** on every window.
4. **Install Git for Windows** (this gives you **Git Bash**, which runs the script):
   <https://git-scm.com/download/win>
   Download, run the installer, click Next through the defaults. You will get a
   **Git Bash** icon.

#### macOS
1. Install **Homebrew** if you don't have it: <https://brew.sh>
2. In the **Terminal** app, run:
   ```
   brew install --cask android-platform-tools
   ```
   (The shorter `brew install android-platform-tools` usually works too.)
   This installs `adb`.

#### Linux (Ubuntu / Debian / Mint)
1. In a terminal, run:
   ```
   sudo apt update
   sudo apt install adb
   ```
   (On some systems the package is named `android-tools-adb` — use that if `adb` is
   not found.)

#### Optional extra: scrcpy (for option 8, screen mirroring)
Only needed if you want to **see and control your phone on your computer**.
Official page: <https://github.com/Genymobile/scrcpy>
- Windows: download the release from that page and unzip it.
- macOS: `brew install scrcpy`
- Linux: `sudo apt install scrcpy`

### C. How to start the program

1. Plug the phone into the computer with a **good USB cable** (see Troubleshooting if it
   only charges).
2. **Unlock** the phone.
3. Open **Git Bash** (Windows) or the **Terminal** (macOS/Linux) **in the folder that
   contains `phone-pro.sh`**.
   - On Windows, the easy way: open the folder in File Explorer, **right-click** an empty
     space, and choose **"Git Bash Here"**.
4. Type this and press Enter:
   ```
   bash phone-pro.sh
   ```
5. The phone shows a pop-up: **"Allow USB debugging?"**
   - **Tick "Always allow from this computer"**, then tap **Allow / OK**.
   - (Ticking the box means you won't be asked again on this computer.)
6. The menu appears. Type a number, press Enter. Type **q** to quit.

> First time? Start with option **1 (Health report)** to check everything is talking
> to the phone. Then try option **7 (backup)** before you remove anything.

---

## 3. Reading the menu

When you run it, you will see a numbered list. You only ever **type one character and
press Enter**. Nothing happens to the phone until you choose. Many options that change
something will **ask you first** — and pressing Enter without typing anything means
**No**.

---

## 4. What each option does (1–13)

**Legend:**
- 🟢 **Safe / read-only** — looks only, changes nothing on the phone.
- 🟡 **Changes something** — but it is reversible (undo column tells you how).
- 💻 **Saves a file on your computer** — nothing changes on the phone, but the file holds
  personal data (see Safety, section 7).

| # | What it does | Type | How to undo |
|---|--------------|------|-------------|
| 1 | **Health report** — shows battery, storage, Android/MIUI version, and how many apps you installed. | 🟢 Safe | Nothing to undo. |
| 2 | **Make the phone feel faster** — sets animations to 0.5x so the phone feels snappier. | 🟡 Changes | Run **option 3**. |
| 3 | **Restore normal animations** — puts animation speed back to normal (1x). | 🟡 Changes | This *is* the undo for option 2. |
| 4 | **Block ads system-wide** — turns on AdGuard Private DNS, which blocks most ads and trackers in every app and browser. | 🟡 Changes | Run **option 5**, or on the phone: **Settings -> Connection & sharing -> Private DNS -> Off**. |
| 5 | **Turn ad-blocking DNS off** — sets Private DNS back to Automatic. | 🟡 Changes | This *is* the undo for option 4. |
| 6 | **Show possible bloatware** — lists pre-installed apps that *might* be junk, and prints the commands to remove/restore them. **Removes nothing.** | 🟢 Safe (read-only) | Nothing to undo. |
| 7 | **Back up photos, documents, downloads** — copies DCIM, Pictures, Documents and Download from the phone into a folder `phone-backup-YYYYMMDD` on your computer. | 💻 Saves files on computer (phone unchanged) | Delete that backup folder on the computer if you don't want it. |
| 8 | **Mirror and control the phone** — shows your phone screen on the computer and lets you use mouse/keyboard (needs **scrcpy**). | 🟢 Safe | Close the scrcpy window. Nothing is left changed. |
| 9 | **Redmi/MIUI clean-up** — removes Xiaomi/Facebook/Netflix ads and junk apps. **Asks about each one** (Enter = No). Removed apps are written to a list file so they can all come back. | 🟡 Changes (reversible) | Run **option 10**. |
| 10 | **Undo option 9** — reinstalls every app that option 9 removed. | 🟡 Changes | This *is* the undo for option 9. |
| 11 | **Privacy audit** — shows which apps can read your SMS, contacts, call history, location, microphone and camera, and flags apps **not from an app store**. Saves a report file on the computer. | 💻 Saves file on computer (read-only on phone) | Nothing changes on the phone. Delete the report file when done (it holds personal data). |
| 12 | **Find unused apps** — lists apps you have not opened in 30+ days and how much space they use. Then **offers** to uninstall them, asking about each (Enter = No). | 🟢 Safe to view / 🟡 if you choose to uninstall | If you uninstall one, reinstall it from the **Play Store** — but note the app's own saved data is gone. |
| 13 | **Battery health log** — shows battery charge, temperature, health and (if the phone reports it) capacity vs. when new. Adds one line to a log file so you can watch the trend. | 💻 Saves file on computer (read-only on phone) | Nothing to undo. Delete the log file to clear the history. |

**Good to know:**
- The removed-apps list is saved at `phone-pro-removed.txt` in your home folder.
- The battery log is saved at `phone-pro-battery-log.csv` in your home folder.
- Options **2, 3, 4, 5** need **"USB debugging (Security settings)"** turned on (setup Step 3).
  If it is off, they will say *"Could not change..."* — see Troubleshooting.

---

## 5. New options (14 and up)

> **Status when this guide was written:** these new tools are **still being built** by
> other helpers. Their own description files (`notes.md`) were **not ready yet**, so the
> list below is the **plan** (taken from the project's merge list), not the final text.
> When a tool is finished and added to the menu, re-read its exact wording in the menu
> itself. **Undo details for each will be filled in from each tool's `notes.md` once
> those exist.**

New tools are numbered **from 14 upward**, in the order shown here. The exact number of
each depends on which ones are finished and included, so treat the numbers below as a
guide, not a promise. They appear in the menu under two headings: **Top picks** and
**More tools**.

### Top picks (planned)

| Likely # | Tool | What it is meant to do |
|----------|------|------------------------|
| 14 | **Free up space** | Clear app caches, show what is filling the phone, and remove junk. |
| 15 | **Battery drain detective** | Show which apps drain the battery, and why. |
| 16 | **Lost-or-stolen check** | A readiness score out of 8, plus an emergency card with your IMEI. |
| 17 | **OTP & SIM scam shield** | Hide one-time passwords (OTPs) on the lock screen and check for sneaky call forwarding. |
| 18 | **Go wireless** | Use this script over Wi-Fi with no cable (and switch back to USB). |

### More tools (planned)

| Likely # | Tool | What it is meant to do |
|----------|------|------------------------|
| 19 | **Security check-up for an old phone** | Check patch age, Chrome/WebView versions and risks. |
| 20 | **Scam & spy app scan** | Look for screen-overlay apps, hidden apps and fake APK files. |
| 21 | **Background app manager** | Put battery hogs to sleep; fix messages that arrive late. |
| 22 | **Why is my phone slow?** | A check-up plus a tune-up. |
| 23 | **Smart photo sync** | Copy only new photos to the computer and free space. |
| 24 | **Reset / new-phone kit** | Make a safety copy of contacts and prepare for a factory reset. |
| 25 | **Phone ↔ PC handoff** | Screenshots, recordings, links, text, files, even webcam. |
| 26 | **Screen comfort** | Display size, bold text, status bar, extra dim. |
| 27 | **Unlock hidden features** | Notification history, IR remote, MIUI tips. |
| 28 | **Charger & cable tester** | Is fast charging really working? |

> If the **"Security check-up for an old phone"** tool is included, the menu will also
> gain an extra quit choice: **"x) Quit and turn off USB debugging (recommended when
> you're done)"**. That is a handy, safe way to close up.

**Features seen but not yet described:** the folder `features/stolen-ready/` exists but
is still empty of its `feature.sh`/`notes.md`, so option "Lost-or-stolen check" is still
in progress. No other feature folders had notes yet when this guide was written.

---

## 6. Troubleshooting

### "No phone found" / no devices
- Make sure the phone is **unlocked** and the cable is firmly plugged into both ends.
- Look at the phone for the **"Allow USB debugging?"** pop-up and tap **Allow**.
- Pull down the notification shade on the phone, tap the USB notification, and choose
  **File transfer (MTP)** instead of "Charging only".
- Try a different **USB port** on the computer (a port directly on the PC, not a hub).
- Check the cable — many cheap cables **only charge** (see below).
- Quick test: run `adb devices` — you should see one line ending in **`device`**.

### "unauthorized"
This means the phone has not yet trusted your computer.
- Unlock the phone and look for the **"Allow USB debugging?"** pop-up. Tick
  **"Always allow from this computer"** and tap **Allow**.
- No pop-up? In **Developer options**, tap **Revoke USB debugging authorisations**,
  then unplug and plug the cable back in — the pop-up should appear.

### "more than one device" / "more than one device/emulator"
The tool expects **exactly one** phone.
- Unplug any other Android phones or tablets.
- Close any phone emulators running on the computer.
- Then run `bash phone-pro.sh` again.

### Options 2–5 say "Could not change..." (MIUI refusing settings)
MIUI blocks setting changes unless a special toggle is on.
- Turn on **Settings -> Additional settings -> Developer options ->
  "USB debugging (Security settings)"**.
- This needs a **SIM card inserted** and a **Mi account signed in**; turning on
  **mobile data** briefly helps it go through.
- Still stuck? In Developer options, some phones also need **"Turn on MIUI
  optimization"** toggled (find it under Developer options / by tapping "Reset to
  default values"), then **reboot** and try again.

### Windows: phone not detected (driver problem)
If Windows does not see the phone at all:
- Install the **Google USB Driver**:
  <https://developer.android.com/studio/run/win-usb>
- Or install the **Xiaomi / Mi USB driver** (Mi PC Suite) from Xiaomi.
- Open **Device Manager** on Windows: the phone should appear without a yellow "!".
  If it has a warning, right-click -> **Update driver** and point it at the driver you
  installed.

### The cable only charges (phone charges but computer can't see it)
- Use a **data cable** — ideally the one that came with the phone. Many cheap or "charge
  only" cables have no data wires inside.
- On the phone, set the USB connection to **File transfer (MTP)** (pull down the
  notification shade, tap the USB notification).

### Git Bash turned "/sdcard" into a Windows path
**Already handled — you don't need to do anything.** The script sets a special switch at
the top so phone paths like `/sdcard` are sent to the phone unchanged. If you ever copy
commands out of the script and run them by hand and see odd paths like
`C:/Program Files/Git/sdcard`, run `export MSYS_NO_PATHCONV=1` first.

---

## 7. Safety notes (please read)

- **The report and backup files hold personal information.** The privacy audit lists
  which apps see your SMS and contacts; the backup folder contains your actual photos and
  documents; the battery log and (later) the emergency card hold device details.
  Keep these files on your own computer.
- **Do not share these files** — not by email, WhatsApp, or uploading them anywhere —
  unless you are sure it is safe. They can reveal private details about you and your phone.
- **Turn USB debugging back off when you are done.**
  Go to **Settings -> Additional settings -> Developer options** and turn **off**
  **USB debugging** (and **USB debugging (Security settings)**). This closes the door so
  no other computer can connect later.
- **Only tick "Always allow"** on a computer that **you own and trust**. On a shared or
  public computer, do not tick it, and use **Revoke USB debugging authorisations** in
  Developer options before you leave.
- **When unsure, press Enter.** Every option that removes or changes something asks first,
  and a blank answer (just Enter) always means **No**.

---

### Quick reference card

| I want to... | Do this |
|--------------|---------|
| Start the tool | Open Git Bash / Terminal in the folder, run `bash phone-pro.sh` |
| Check the phone is connected | Option **1**, or run `adb devices` |
| Make the phone feel faster | Option **2** (undo with **3**) |
| Block ads everywhere | Option **4** (undo with **5**) |
| Remove Xiaomi ads/junk safely | Option **9** (undo with **10**) |
| Back up my photos first | Option **7** |
| See which apps spy on me | Option **11** |
| Clear out apps I never use | Option **12** |
| Check my battery's health | Option **13** |
| Finish safely | Quit (**q**), then turn off USB debugging on the phone |
