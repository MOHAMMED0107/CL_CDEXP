# free-space

## Menu line

```
14) Free up space: clear app cache, see what fills the phone, remove junk
```

Entry function: `free_space` (feature.sh defines only functions and `fs_*` constants).

## What it does (for the user)

1. Shows how much storage is used and free right now (in MB/GB).
2. Offers to clear the temporary cache of all apps in one go. Chats, photos, passwords and logins are not touched. Shows how much space came back.
3. Shows what fills the phone: camera photos, Pictures, Screenshots, Movies, Download, WhatsApp, Telegram, all apps together (plus the 5 biggest apps) and the 10 biggest files.
4. Finds hidden junk: Android's trash, the MIUI Gallery recycle bin, old app installer files (.apk), old WhatsApp chat backups (the newest one is always kept), folders left behind by removed apps, and MIUI debug logs. Each kind is deleted only if you type y for it.
5. Deleting is permanent, so before each deletion it offers to copy the files to this computer (folder `phone-junk-YYYYMMDD`). The next time you run it, it offers to put them back.

## Safety

- Read-only unless you type y. Enter, n, or no input at all means No. Tests check that the phone gets no trim, delete or push when every answer is No.
- Every path is checked again before deleting. It must be inside `/sdcard/`, contain no `..`, and belong to its category. Folders can only be deleted directly under `Android/data` or `Android/media`.
- If copying a file to the computer fails or the copy is incomplete (size is checked), that file is kept on the phone.
- Each line in the undo file is written after the copy and before the delete.
- WhatsApp: the dated backups `msgstore-YYYY-MM-DD.N.db.cryptNN` are only offered in a folder that also has the newest `msgstore.db.cryptNN`. The newest backup is never touched.
- In-progress downloads (`.pending-*`) are never touched.
- "Left behind" folders are checked against `pm list packages -u`, which also lists apps removed only for user 0 (option 9) and apps in Second space or Dual apps. The check is skipped if fewer than 20 apps come back, because then the list is clearly unreadable.
- Chat and photo apps are never offered for deletion, even when the app is gone: WhatsApp (and Business and mods), Telegram, Signal, Viber, LINE, Messenger, Snapchat, Instagram, Google Photos, MIUI Gallery. A WhatsApp reinstall needs its folder to restore chats. `com.android.*` is never offered either.
- Nothing here touches calls, SMS/OTP, notifications or banking apps. Clearing the cache does not log anyone out.

## Files it writes

- `$HOME/phone-pro-free-space-undo.txt`: copies that can be put back. One line per item, tab-separated: computer folder, copy, phone path, kind (f or d), bytes. It is removed once everything has been put back.
- `$HOME/phone-pro-free-space-log.txt`: one line per deleted item (date, kind, bytes, phone path, copy or `-`).
- `./phone-junk-YYYYMMDD/sdcard/...`: the copies, only if you asked for them. They are kept after a put-back; the user deletes them by hand.

## Facts checked (Android 12, adb shell user uid 2000, not rooted)

- `pm trim-caches 999G`: the Shell package's manifest holds `android.permission.CLEAR_APP_CACHE` (AOSP android12-release `packages/Shell/AndroidManifest.xml`). `runTrimCaches` accepts a K/M/G suffix (or a plain byte count) and calls `freeStorageAndNotify(..., FLAG_ALLOCATE_DEFY_ALL_RESERVED)`, which is not "aggressive". On success it prints nothing. If it is refused it prints `Exception occurred while executing 'trim-caches': java.lang.SecurityException...`, which is detected and explained.
- `dumpsys diskstats` (needs DUMP, which the shell has): it prints `App Size:`, `App Data Size:`, `App Cache Size:`, `Package Names: [...]`, `App Sizes: [...]` and `App Data Sizes: [...]` from `/data/system/diskstats_cache.json`. These lines are missing until Android's daily measurement has run, which is handled. App data already includes cache (StorageStats.getDataBytes), so the total shown is app + data.
- Android/data and Android/media: the storage daemon (MediaProvider FuseDaemon `is_app_accessible_path`) lets `uid < AID_APP_START (10000)` through, so the shell can list and delete there. If a phone refuses, the feature says so and skips that part.
- Trash: MediaProvider renames trashed items to `.trashed-<expiry epoch seconds>-<name>` (30 days) and pending items to `.pending-<expiry>-<name>` (7 days).
- toybox: `find -size +20480` counts 512-byte blocks, so it means more than 10 MB. `-iname`, `( -o )` and `-exec ... {} +` are supported. `du -s` prints KB, a tab, then the path. `stat -c '%s %n'` prints bytes, a space, then the name, so names with spaces work. `find /sdcard/` has a trailing slash because `/sdcard` is a symlink.
- MIUI paths: `MIUI/debug_log` holds system logs (Xiaomi support article KA-07847). The Gallery recycle bin is `MIUI/Gallery/cloud/.trashBin`. `Android/media/com.miui.gallery/cloud/.trashBin` is also checked.

## Limitations

- App sizes and the cache figure come from Android's last daily measurement, so they can be a day old, or missing on a freshly reset phone.
- The biggest-files list only covers shared storage (`/sdcard`) and files over 10 MB. App-private storage (`/data/data`) cannot be read without root.
- MIUI Gallery recycle bin: the folder is not documented by Xiaomi. If it is not found, the user is pointed to Gallery > Albums > Trash bin. After deleting files there, Gallery may show empty placeholders until it refreshes.
- Clearing the cache cannot be undone, and does not need to be: apps rebuild their cache. Deleting without a copy cannot be undone, and the feature says so every time.
- Putting back a "left behind" app folder (`adb push` into `Android/data`) may be refused by some phones. The copy then stays on the computer and the item stays listed.
- File names with a tab or newline are skipped. On Windows, names the PC cannot store (for example names containing `:`) cannot be copied, so those files are kept on the phone.
- The search runs `find` over all of `/sdcard`, so a phone with very many files can take a minute or two.

## Tests

`test/run-tests.sh` (167 checks, about 20 s) runs the feature through `harness/feature-run.sh` against `test/bin/adb`. That fake adb emulates the phone's shared storage from `test/fixtures/<mode>/files.txt`, replies with `\r\n` line endings, and records deletions, copies, pushes and cache trims. It answers only the exact command strings the feature sends; anything else fails the tests.

What the tests cover:
- Static bash 3.2 and portability checks, plus the "functions and `fs_` constants only" rule.
- The happy path, with copy failures and delete failures. The set of deleted items must match exactly.
- Enter, No and no-input runs, with no change on the phone.
- Undo: declining, full put-back, and partial put-back.
- Unreadable or refused data: df denied, no diskstats cache, SecurityException on trim, unreadable app list, `ls` denied, a wrapped df line, empty app lists.
- The same run under BWK awk (macOS-style) and `gawk --posix`, with identical output.
- No global variable leaks.
- A cross-check: the exact on-phone command strings are run with dash plus real find, stat and ls on a local copy of the fixture tree, and must give the same answers as the fake.
