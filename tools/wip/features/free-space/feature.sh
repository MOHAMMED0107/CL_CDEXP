# ---------- Free up space (feature: free-space) ----------
# Read-only unless you type y. Shows free space and what fills the phone, offers to clear every
# app's temporary cache (pm trim-caches), then shows hidden junk one kind at a time.
# Each kind is deleted only after its own y; files can be copied to this computer first
# (./phone-junk-YYYYMMDD) and the next run offers to put them back. Nothing else is touched.
#
# Phone-side facts this relies on (Android 12, adb shell user = uid 2000, no root):
#  - "pm trim-caches SIZE" needs CLEAR_APP_CACHE, which the Shell package holds. SIZE takes a
#    K/M/G suffix; it asks Android to free caches until SIZE is free, and prints nothing on success.
#  - "df /data" prints 1K-blocks. "dumpsys diskstats" shows app sizes from Android's daily
#    measurement (missing until that has run once). App Data Size already includes the cache.
#  - Android 11+ moves deleted media to ".trashed-<expiry seconds>-<name>" next to the original,
#    deleted for good after 30 days. Files are listed with toybox: find + stat -c '%s %n'.
#  - Android/data and Android/media are readable by the shell user (the storage daemon lets
#    system uids below 10000 in); if a phone refuses, that check is skipped.

fs_undo="$HOME/phone-pro-free-space-undo.txt"   # copies kept on this computer (so they can be put back)
fs_log="$HOME/phone-pro-free-space-log.txt"     # one line per item this option deleted
fs_tab=$'\t'
fs_big_min=10485760   # "biggest files" = over 10 MB (find -size +20480 counts 512-byte blocks)

fs_cmd_df='df /data'
fs_cmd_trim='pm trim-caches 999G 2>&1'
fs_cmd_disk='dumpsys diskstats'
fs_cmd_pkgs='pm list packages -u'
# One pass over the whole shared storage: big files and Android trash files.
fs_cmd_scan="find /sdcard/ -type f '(' -size +20480 -o -name '.trashed-*' ')' -exec stat -c '%s %n' {} + 2>/dev/null"
fs_cmd_miuibin="find /sdcard/MIUI/Gallery/cloud/.trashBin /sdcard/Android/media/com.miui.gallery/cloud/.trashBin -type f -exec stat -c '%s %n' {} + 2>/dev/null"
fs_cmd_apk="find /sdcard/Download '/sdcard/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents' '/sdcard/WhatsApp/Media/WhatsApp Documents' '/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Documents' /sdcard/Telegram /sdcard/Android/data/org.telegram.messenger/files/Telegram /sdcard/Android/data/org.telegram.messenger.web/files/Telegram -type f '(' -iname '*.apk' -o -iname '*.xapk' -o -iname '*.apks' ')' -exec stat -c '%s %n' {} + 2>/dev/null"
fs_cmd_wa="find /sdcard/Android/media/com.whatsapp/WhatsApp/Databases /sdcard/WhatsApp/Databases '/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Databases' '/sdcard/WhatsApp Business/Databases' -maxdepth 1 -type f -name 'msgstore*' -exec stat -c '%s %n' {} + 2>/dev/null"
fs_cmd_logs="find /sdcard/MIUI/debug_log -type f -exec stat -c '%s %n' {} + 2>/dev/null"
fs_cmd_lsdata='ls -1 /sdcard/Android/data 2>/dev/null || echo FS_DENIED'
fs_cmd_lsmedia='ls -1 /sdcard/Android/media 2>/dev/null || echo FS_DENIED'

# Folder report rows: "label|path;path". A leading "?" hides the row when none of its paths exist.
fs_folders=(
  "Camera photos and videos (DCIM)|/sdcard/DCIM"
  "Pictures (saved and edited images)|/sdcard/Pictures"
  "Screenshots (already counted above)|/sdcard/DCIM/Screenshots;/sdcard/Pictures/Screenshots"
  "Movies|/sdcard/Movies"
  "Download|/sdcard/Download"
  "WhatsApp photos, videos and voice notes|/sdcard/Android/media/com.whatsapp/WhatsApp/Media;/sdcard/WhatsApp/Media"
  "?WhatsApp Business photos and videos|/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Media;/sdcard/WhatsApp Business/Media"
  "Telegram|/sdcard/Telegram;/sdcard/Android/data/org.telegram.messenger/files/Telegram;/sdcard/Android/data/org.telegram.messenger.web/files/Telegram"
)

# Folders never offered as "left behind", even when the app is gone: chat apps and galleries keep
# chats, chat backups and photos there (WhatsApp's restore needs its folder before reinstalling).
fs_keep_pkgs="com.whatsapp com.whatsapp.w4b com.gbwhatsapp com.yowhatsapp com.fmwhatsapp com.whatsapp.plus org.telegram.messenger org.telegram.messenger.web org.thunderdog.challegram org.thoughtcrime.securesms com.viber.voip jp.naver.line.android com.facebook.orca com.snapchat.android com.instagram.android com.google.android.apps.photos com.miui.gallery"

# awk helpers shared by several reports: human-readable size, path relative to /sdcard.
fs_awk_lib='
function hum(b) {
  if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824)
  if (b >= 1048576) return sprintf("%.0f MB", b / 1048576)
  if (b >= 1024) return sprintf("%.0f KB", b / 1024)
  return sprintf("%.0f bytes", b)
}
function rel(p) { if (index(p, "/sdcard/") == 1) return substr(p, 9); return p }
'

fs_hum() { awk -v b="${1:-0}" "$fs_awk_lib"'BEGIN { print hum(b + 0) }'; }
fs_rel() { case "$1" in /sdcard/*) printf '%s\n' "${1#/sdcard/}" ;; *) printf '%s\n' "$1" ;; esac; }
# Quote a path for the phone's shell: wrap in single quotes, escape single quotes inside.
fs_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# y/N question; Enter (or no input at all) means No.
fs_ask() {
  local a=""
  read -r -p "$1 [y/N] " a || a=""
  case "$a" in y|Y|yes|Yes|YES) return 0 ;; esac
  return 1
}

# Only plain paths inside /sdcard/ may ever be deleted; folders only directly in Android/data or Android/media.
fs_safe_path() {
  case "$1" in /sdcard/?*) ;; *) return 1 ;; esac
  case "$1" in */../*|*/..|*/./*|*/.|*//*|*"$fs_tab"*) return 1 ;; esac
  if [ "$2" = d ]; then
    case "$1" in
      /sdcard/Android/data/*/*|/sdcard/Android/media/*/*) return 1 ;;
      /sdcard/Android/data/?*|/sdcard/Android/media/?*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# "size path" lines from toybox stat -c '%s %n' -> "bytes<TAB>path<TAB>f". Odd lines are dropped.
fs_parse_stat() {
  awk '{
    s = $1
    if (s !~ /^[0-9]+$/) next
    p = substr($0, length(s) + 2)
    gsub(/\/\/+/, "/", p)
    if (index(p, "/sdcard/") != 1 || index(p, "\t") > 0) next
    print s "\t" p "\tf"
  }'
}

# Drop paths already offered by an earlier category (stdin -> stdout).
fs_unseen() { awk -F'\t' 'FILENAME == ARGV[1] { seen[$2] = 1; next } !($2 in seen)' "$TMPD/fs_seen" -; }

# df /data -> "total_kb used_kb avail_kb use%" (empty if unreadable). Copes with a wrapped line.
fs_df() {
  ash "$fs_cmd_df" 2>/dev/null | awk '
    $1 == "Filesystem" { next }
    { line = line " " $0 }
    END {
      n = split(line, f, " ")
      if (n >= 6 && f[n] == "/data" && f[n-4] ~ /^[0-9]+$/ && f[n-3] ~ /^[0-9]+$/ && f[n-2] ~ /^[0-9]+$/)
        print f[n-4], f[n-3], f[n-2], f[n-1]
    }'
}

fs_show_df() {
  if [ -z "$1" ]; then
    echo "  Could not read the storage size from the phone (carrying on without it)."
    return 0
  fi
  set -- $1
  echo "  Used: $(fs_hum $(($2 * 1024)))   Free: $(fs_hum $(($3 * 1024)))   Total: $(fs_hum $(($1 * 1024)))   ($4 full)"
}

# ---- Undo: put back what an earlier run copied to this computer before deleting ----
fs_offer_restore() {
  [ -s "$fs_undo" ] || return 0
  local n total base lp remote kind bytes target ok=0 bad=0
  n=$(awk 'END { print NR }' "$fs_undo")
  total=$(awk -F'\t' '{ s += $5 } END { printf "%.0f", s }' "$fs_undo")
  echo
  echo "== Put back files from last time? =="
  echo "  Earlier, $n deleted item(s) ($(fs_hum "$total")) were copied to this computer before deleting."
  if ! fs_ask "Put them back on the phone now?"; then
    echo "  Left as is. The copies stay on this computer."
    echo "  To stop this question, delete this file: $fs_undo"
    return 0
  fi
  : >"$TMPD/fs_undo_left"
  while IFS="$fs_tab" read -r base lp remote kind bytes <&3; do
    [ -n "$remote" ] || continue
    if ! fs_safe_path "$remote" "$kind" || [ ! -e "$base/$lp" ]; then
      echo "  Copy not found, skipped: $base/$lp"
      printf '%s\t%s\t%s\t%s\t%s\n' "$base" "$lp" "$remote" "$kind" "$bytes" >>"$TMPD/fs_undo_left"
      bad=$((bad + 1))
      continue
    fi
    target=$remote
    [ "$kind" = d ] && target="${remote%/*}/"
    if (cd "$base" && adb push "$lp" "$target" </dev/null >/dev/null 2>&1) &&
       [ "$(ash "[ -e $(fs_q "$remote") ] && echo FS_OK")" = FS_OK ]; then
      ok=$((ok + 1))
    else
      echo "  Could not put back $(fs_rel "$remote") (the copy is still in $base/$lp)."
      printf '%s\t%s\t%s\t%s\t%s\n' "$base" "$lp" "$remote" "$kind" "$bytes" >>"$TMPD/fs_undo_left"
      bad=$((bad + 1))
    fi
  done 3<"$fs_undo"
  if [ -s "$TMPD/fs_undo_left" ]; then cp "$TMPD/fs_undo_left" "$fs_undo"; else rm -f "$fs_undo"; fi
  echo "  Put back $ok of $n item(s)."
  [ "$bad" -eq 0 ] || echo "  $bad item(s) could not be put back; they stay listed for next time."
  [ "$ok" -eq 0 ] || echo "  The copies on this computer were left in place; delete them yourself when you no longer need them."
}

# ---- Step 1: clear all apps' temporary cache ----
fs_step_cache() {
  local before=$1 after cache out gained
  echo
  echo "== Step 1: clear temporary app cache =="
  echo "  Apps keep temporary files (thumbnails, web pages, previews) so they open faster."
  echo "  Clearing them is safe: no chats, photos, passwords or logins are touched, and apps"
  echo "  rebuild what they need by themselves. Some apps may open a little slower the first time."
  cache=$(awk '/^App Cache Size:/ { print $4; exit }' "$TMPD/fs_disk")
  case "$cache" in
    ''|*[!0-9]*) ;;
    *) echo "  Android's last measurement: about $(fs_hum "$cache") of temporary cache." ;;
  esac
  if ! fs_ask "Clear the temporary cache of ALL apps now?"; then
    echo "  Skipped."
    return 0
  fi
  echo "  Clearing (this can take up to a minute)..."
  out=$(ash "$fs_cmd_trim")
  if printf '%s\n' "$out" | grep -qi -E 'exception|error|denied|not found|unknown'; then
    echo "  The phone refused to clear the cache over USB, so nothing was changed."
    echo "  Reason given: $(printf '%s\n' "$out" | grep -i -E 'exception|error|denied|not found|unknown' | tail -n 1 | cut -c 1-150)"
    echo "  You can do it on the phone instead: Security app > Cleaner."
    return 0
  fi
  after=$(fs_df)
  if [ -n "$before" ] && [ -n "$after" ]; then
    set -- $before; gained=$3
    set -- $after; gained=$(($3 - gained))
    if [ "$gained" -gt 1024 ]; then
      fs_trim_freed=$((gained * 1024))
      echo "  Done. Space that came back: $(fs_hum "$fs_trim_freed")   (free now: $(fs_hum $(($3 * 1024))))"
    else
      echo "  Done. Hardly any space came back: the cache was already small."
    fi
  else
    echo "  Done. (Could not measure how much space came back.)"
  fi
  echo "  Nothing to undo here: apps rebuild their cache by themselves when needed."
}

# ---- Step 2: what fills the phone (read-only) ----
fs_folder_sizes() {
  local cmd="du -s" row paths p
  printf '%s\n' "${fs_folders[@]}" >"$TMPD/fs_rows"
  for row in "${fs_folders[@]}"; do
    paths=${row#*|}
    while :; do
      p=${paths%%;*}
      cmd="$cmd $(fs_q "$p")"
      [ "$p" = "$paths" ] && break
      paths=${paths#*;}
    done
  done
  ash "$cmd 2>/dev/null" >"$TMPD/fs_du"
  if ! grep -q '^[0-9]' "$TMPD/fs_du"; then
    echo "  Could not measure the folders (the phone did not allow it, or they do not exist)."
    return 0
  fi
  awk -F'\t' "$fs_awk_lib"'
    FILENAME == ARGV[1] { if ($1 ~ /^[0-9]+$/) kb[$2] = $1; next }
    {
      split($0, f, "|"); label = f[1]; opt = 0
      if (substr(label, 1, 1) == "?") { opt = 1; label = substr(label, 2) }
      n = split(f[2], p, ";"); found = 0; tot = 0
      for (i = 1; i <= n; i++) if (p[i] in kb) { found = 1; tot += kb[p[i]] }
      if (!found && opt) next
      printf "  %-42s %10s\n", label, (found ? hum(tot * 1024) : "not found")
    }' "$TMPD/fs_du" "$TMPD/fs_rows"
}

fs_app_sizes() {
  awk "$fs_awk_lib"'
    function list_of(line, out,   s) { s = line; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s); gsub(/"/, "", s); return split(s, out, ",") }
    /^App Size:/ { a = $3 }
    /^App Data Size:/ { d = $4 }
    /^App Cache Size:/ { c = $4 }
    /^Package Names:/ { np = list_of($0, names) }
    /^App Sizes:/ { list_of($0, asz) }
    /^App Data Sizes:/ { list_of($0, dsz) }
    END {
      if (a !~ /^[0-9]+$/ || d !~ /^[0-9]+$/) {
        print "  App sizes: Android has not measured them yet (it does this about once a day while"
        print "  the phone is idle). Try again tomorrow."
        exit
      }
      printf "  %-42s %10s\n", "Apps and their data (all apps together)", hum(a + d)
      if (c ~ /^[0-9]+$/) printf "  %-42s %10s\n", "  of which temporary cache (Step 1)", hum(c)
      shown = 0
      for (i = 1; i <= np; i++) { s[i] = asz[i] + dsz[i]; used[i] = 0 }
      for (k = 1; k <= 5 && k <= np; k++) {
        best = 0
        for (i = 1; i <= np; i++) if (!used[i] && (best == 0 || s[i] > s[best])) best = i
        used[best] = 1
        if (s[best] <= 0) break
        if (!shown) { print "  Biggest apps (app plus its data):"; shown = 1 }
        printf "     %9s  %s\n", hum(s[best]), names[best]
      }
      print "  (Android measures app sizes about once a day, so these can be a day old.)"
    }' "$TMPD/fs_disk"
}

fs_biggest_files() {
  echo "  Searching for big files (this can take a minute)..."
  ash "$fs_cmd_scan" | fs_parse_stat >"$TMPD/fs_scan"
  awk -F'\t' -v min="$fs_big_min" '$1 + 0 > min + 0' "$TMPD/fs_scan" | sort -t "$fs_tab" -k1,1nr | head -n 10 >"$TMPD/fs_big"
  if [ ! -s "$TMPD/fs_big" ]; then
    echo "  No files over 10 MB found (or the phone did not allow the search)."
    return 0
  fi
  echo "  The 10 biggest files (over 10 MB):"
  awk -F'\t' "$fs_awk_lib"'{
    n = split($2, a, "/"); note = ""
    if (tolower(a[n]) ~ /^\.trashed-/) note = "   (in Android'"'"'s trash, see Step 3)"
    else if ($2 ~ /^\/sdcard\/Android\/(data|obb)\//) note = "   (an app'"'"'s own file: manage it inside that app)"
    printf "     %9s  %s%s\n", hum($1), rel($2), note
  }' "$TMPD/fs_big"
}

fs_step_report() {
  echo
  echo "== Step 2: what is filling your phone =="
  echo "  Measuring folders (this can take a minute)..."
  fs_folder_sizes
  echo
  fs_app_sizes
  echo
  fs_biggest_files
  echo
  echo "  Tips: WhatsApp > Settings > Storage and data > Manage storage shows big chats and videos."
  echo "        Telegram > Settings > Data and Storage > Storage Usage can clear its cache."
  echo "        Option 7 copies your photos to this computer, so you can then delete them from the phone."
}

# ---- Step 3: hidden junk, one kind at a time ----
# List file: "bytes<TAB>path<TAB>kind" (kind f = file, d = folder). Extra arguments are explanation
# lines; lines in the file named by $fs_notes are printed too (also when nothing was found).
# Returns 1 if the list is empty.
fs_offer_delete() {
  local list=$1 title=$2 noun=$3 n total
  shift 3
  n=$(awk 'END { print NR }' "$list")
  echo
  if [ "$n" -eq 0 ]; then
    echo "-- $title: nothing found --"
    fs_print_notes
    return 1
  fi
  [ "$n" -eq 1 ] || noun="${noun}s"
  sort -t "$fs_tab" -k1,1nr "$list" >"$TMPD/fs_sorted" && cp "$TMPD/fs_sorted" "$list"
  total=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$list")
  echo "-- $title: $n $noun, $(fs_hum "$total") --"
  while [ $# -gt 0 ]; do echo "   $1"; shift; done
  awk -F'\t' "$fs_awk_lib"'
    NR <= 5 { printf "     %9s  %s\n", hum($1), rel($2) }
    END { if (NR > 5) printf "     ... and %d more\n", NR - 5 }' "$list"
  fs_print_notes
  cat "$list" >>"$TMPD/fs_seen"
  if ! fs_ask "Delete these $n $noun now? Deleting is permanent."; then
    echo "   Kept."
    return 0
  fi
  if fs_ask "Copy them to this computer first (into the folder $fs_junk_dir here), so you can put them back later?"; then
    fs_delete_list "$list" "$title" 1 "$noun" "$n"
  else
    fs_delete_list "$list" "$title" 0 "$noun" "$n"
  fi
  return 0
}

fs_print_notes() {
  local line
  if [ -n "$fs_notes" ] && [ -s "$fs_notes" ]; then
    while IFS= read -r line <&3; do echo "   $line"; done 3<"$fs_notes"
  fi
  fs_notes=""
}

fs_pull() {  # remote local kind bytes -> 0 only if a complete copy is on this computer
  local dir
  dir=$(dirname "$2")
  mkdir -p "$dir" 2>/dev/null || return 1
  if [ "$3" = d ]; then
    adb pull "$1" "$dir/" </dev/null >/dev/null 2>&1 && mkdir -p "$2" 2>/dev/null && [ -d "$2" ]
  else
    adb pull "$1" "$2" </dev/null >/dev/null 2>&1 && [ -f "$2" ] && [ "$(wc -c <"$2" | tr -d ' ')" = "$4" ]
  fi
}

fs_rm() {  # path kind -> 0 if it is gone from the phone afterwards
  local q out
  fs_safe_path "$1" "$2" || return 1
  q=$(fs_q "$1")
  if [ "$2" = d ]; then
    out=$(ash "rm -rf $q && [ ! -e $q ] && echo FS_GONE" 2>/dev/null)
  else
    out=$(ash "rm -f $q && [ ! -e $q ] && echo FS_GONE" 2>/dev/null)
  fi
  [ "$out" = FS_GONE ]
}

fs_delete_list() {  # list title copy(0/1) noun count
  local list=$1 title=$2 copy=$3 noun=$4 n=$5 bytes path kind lp now base gone=0 failed=0 kept=0 freed=0
  now=$(date '+%Y-%m-%d %H:%M')
  base=$(pwd)
  if [ "$copy" = 1 ] && ! mkdir -p "$fs_junk_dir" 2>/dev/null; then
    echo "   Could not create the folder $base/$fs_junk_dir, so nothing was deleted."
    return 0
  fi
  while IFS="$fs_tab" read -r bytes path kind <&3; do
    [ -n "$path" ] || continue
    if ! fs_safe_path "$path" "$kind"; then
      echo "   Skipped an unusual path: $path"
      continue
    fi
    lp="-"
    if [ "$copy" = 1 ]; then
      lp="$fs_junk_dir$path"
      if ! fs_pull "$path" "$lp" "$kind" "$bytes"; then
        echo "   Could not copy $(fs_rel "$path"), so it was kept on the phone."
        kept=$((kept + 1))
        continue
      fi
      # Saved before deleting, so the next run can put it back.
      printf '%s\t%s\t%s\t%s\t%s\n' "$base" "$lp" "$path" "$kind" "$bytes" >>"$fs_undo"
      fs_copied=1
    fi
    if fs_rm "$path" "$kind"; then
      gone=$((gone + 1))
      freed=$((freed + bytes))
      printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$title" "$bytes" "$path" "$lp" >>"$fs_log"
    else
      echo "   Could not delete $(fs_rel "$path") (left as is)."
      failed=$((failed + 1))
    fi
  done 3<"$list"
  fs_freed_total=$((fs_freed_total + freed))
  echo "   Deleted $gone of $n $noun ($(fs_hum "$freed") freed)."
  [ "$kept" -eq 0 ] || echo "   Kept $kept because they could not be copied to this computer first."
  [ "$failed" -eq 0 ] || echo "   $failed could not be deleted (the phone refused); they were left as they are."
  if [ "$gone" -gt 0 ]; then
    if [ "$copy" = 1 ]; then
      echo "   Copied first to: $base/$fs_junk_dir"
      echo "   To put them back on the phone, run this option again."
    else
      echo "   This cannot be undone."
    fi
  fi
}

fs_junk_trash() {
  local days
  awk -F'\t' '{ n = split($2, a, "/"); b = tolower(a[n]) }
    b ~ /^\.trashed-[0-9]+-/ && $2 !~ /^\/sdcard\/Android\/(data|obb)\// { print }' "$TMPD/fs_scan" | fs_unseen >"$TMPD/fs_c_trash"
  days=$(awk -F'\t' -v now="$(date +%s)" '{
      n = split($2, a, "/"); b = tolower(a[n]); sub(/^\.trashed-/, "", b)
      d = (b + 0 - now) / 86400; if (d > m) m = d
    } END { if (m > 0) printf "%.0f", m + 0.5 }' "$TMPD/fs_c_trash")
  if [ -n "$days" ]; then days="within $days days"; else days="any day now"; fi
  fs_offer_delete "$TMPD/fs_c_trash" "Android's trash (photos, videos and files you deleted)" "file" \
    "Android keeps deleted items for 30 days, then removes them by itself ($days anyway)." \
    "Deleting them now just frees the space sooner."
}

fs_junk_miui_bin() {
  ash "$fs_cmd_miuibin" | fs_parse_stat | awk -F'\t' '
    index($2, "/sdcard/MIUI/Gallery/cloud/.trashBin/") == 1 || index($2, "/sdcard/Android/media/com.miui.gallery/cloud/.trashBin/") == 1' \
    | fs_unseen >"$TMPD/fs_c_bin"
  if ! fs_offer_delete "$TMPD/fs_c_bin" "MIUI Gallery recycle bin" "file" \
      "Photos you deleted in the Gallery app; the Gallery empties this bin by itself after 30 days." \
      "The cleanest way is Gallery > Albums > Trash bin > Empty; deleting here frees the same space."; then
    echo "   (Not found or not readable over USB. To be sure, check Gallery > Albums > Trash bin.)"
  fi
}

fs_junk_apks() {
  ash "$fs_cmd_apk" | fs_parse_stat | awk -F'\t' '
    BEGIN {
      r[1] = "/sdcard/Download/"
      r[2] = "/sdcard/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents/"
      r[3] = "/sdcard/WhatsApp/Media/WhatsApp Documents/"
      r[4] = "/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Documents/"
      r[5] = "/sdcard/Telegram/"
      r[6] = "/sdcard/Android/data/org.telegram.messenger/files/Telegram/"
      r[7] = "/sdcard/Android/data/org.telegram.messenger.web/files/Telegram/"
    }
    {
      ok = 0
      for (i = 1; i <= 7; i++) if (index($2, r[i]) == 1) ok = 1
      n = split($2, a, "/"); b = tolower(a[n])
      if (ok && b ~ /\.(apk|xapk|apks)$/ && b !~ /^\.(trashed|pending)-/) print
    }' | fs_unseen >"$TMPD/fs_c_apk"
  fs_offer_delete "$TMPD/fs_c_apk" "Leftover app installer files (.apk) in Download, WhatsApp and Telegram" "file" \
    "Once an app is installed its installer file is not needed. Installed apps keep working."
}

fs_junk_wa() {
  local tag p
  : >"$TMPD/fs_c_wa"
  : >"$TMPD/fs_wa_notes"
  ash "$fs_cmd_wa" | fs_parse_stat | fs_unseen | awk -F'\t' -v list="$TMPD/fs_c_wa" -v notes="$TMPD/fs_wa_notes" '
    BEGIN {
      d[1] = "/sdcard/Android/media/com.whatsapp/WhatsApp/Databases"
      d[2] = "/sdcard/WhatsApp/Databases"
      d[3] = "/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Databases"
      d[4] = "/sdcard/WhatsApp Business/Databases"
    }
    {
      n = split($2, a, "/"); b = a[n]; dir = substr($2, 1, length($2) - length(b) - 1)
      ok = 0
      for (i = 1; i <= 4; i++) if (dir == d[i]) ok = 1
      if (!ok) next
      if (b ~ /^msgstore\.db\.crypt[0-9]+$/) { latest[dir] = b; next }
      if (b ~ /^msgstore-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.[0-9]+\.db\.crypt[0-9]+$/) { k++; line[k] = $0; ldir[k] = dir }
    }
    END {
      for (i = 1; i <= k; i++) {
        if (ldir[i] in latest) print line[i] > list
        else nolatest[ldir[i]] = 1
      }
      for (x in latest) print "KEEP\t" x "/" latest[x] > notes
      for (x in nolatest) print "NOLATEST\t" x > notes
    }'
  sort "$TMPD/fs_wa_notes" >"$TMPD/fs_wa_notes.sorted"
  while IFS="$fs_tab" read -r tag p <&3; do
    case "$tag" in
      KEEP) echo "Always kept (newest backup): $(fs_rel "$p")" ;;
      NOLATEST) echo "Left alone: $(fs_rel "$p") has old backups but no newest backup (msgstore.db.crypt...), so nothing there is touched." ;;
    esac
  done 3<"$TMPD/fs_wa_notes.sorted" >"$TMPD/fs_notes_wa"
  fs_notes="$TMPD/fs_notes_wa"
  fs_offer_delete "$TMPD/fs_c_wa" "Old WhatsApp daily chat backups" "file" \
    "WhatsApp saves a chat backup on the phone every night and keeps about a week of older copies." \
    "Only those older copies are listed. The newest backup is always kept, and your chats in" \
    "WhatsApp and your Google Drive backup are not affected."
}

fs_junk_leftovers() {
  local npk cmd p tag denied=""
  ash "$fs_cmd_pkgs" | sed 's/^package://' | pkgs_only | sort -u >"$TMPD/fs_pkgs"
  : >"$TMPD/fs_c_left"
  npk=$(awk 'END { print NR }' "$TMPD/fs_pkgs")
  if [ "$npk" -lt 20 ]; then
    echo
    echo "-- Folders left behind by apps you removed: skipped --"
    echo "   Could not read the list of installed apps, so this check was skipped to stay safe."
    return 0
  fi
  ash "$fs_cmd_lsdata" >"$TMPD/fs_lsdata"
  ash "$fs_cmd_lsmedia" >"$TMPD/fs_lsmedia"
  grep -qx FS_DENIED "$TMPD/fs_lsdata" && denied="Android/data"
  grep -qx FS_DENIED "$TMPD/fs_lsmedia" && denied="${denied:+$denied and }Android/media"
  awk -v keep=" $fs_keep_pkgs " '
    FILENAME == ARGV[1] { inst[$0] = 1; next }
    $0 == "FS_DENIED" { next }
    $0 !~ /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/ { next }
    ($0 in inst) { next }
    {
      where = (FILENAME == ARGV[2]) ? "data" : "media"
      if (index(keep, " " $0 " ") > 0 || $0 ~ /^com\.android\./) print "KEEP\t/sdcard/Android/" where "/" $0
      else print "CAND\t/sdcard/Android/" where "/" $0
    }' "$TMPD/fs_pkgs" "$TMPD/fs_lsdata" "$TMPD/fs_lsmedia" >"$TMPD/fs_left_raw"
  cmd="du -s"
  while IFS="$fs_tab" read -r tag p <&3; do
    [ "$tag" = CAND ] && cmd="$cmd $(fs_q "$p")"
  done 3<"$TMPD/fs_left_raw"
  if [ "$cmd" != "du -s" ]; then
    ash "$cmd 2>/dev/null" | awk -F'\t' 'FILENAME == ARGV[1] { if ($1 == "CAND") c[$2] = 1; next }
      $1 ~ /^[0-9]+$/ && ($2 in c) { printf "%.0f\t%s\td\n", $1 * 1024, $2 }' "$TMPD/fs_left_raw" - | fs_unseen >"$TMPD/fs_c_left"
  fi
  while IFS="$fs_tab" read -r tag p <&3; do
    [ "$tag" = KEEP ] && echo "Kept on purpose: $(fs_rel "$p") (chat and photo apps keep chats and photos here; reinstall the app to use them)."
  done 3<"$TMPD/fs_left_raw" >"$TMPD/fs_notes_left"
  [ -z "$denied" ] || echo "Could not look inside $denied (the phone did not allow it), so that part was skipped." >>"$TMPD/fs_notes_left"
  fs_notes="$TMPD/fs_notes_left"
  fs_offer_delete "$TMPD/fs_c_left" "Folders left behind by apps you removed" "folder" \
    "These belong to apps that are no longer on the phone (checked against Android's app list)."
}

fs_junk_logs() {
  ash "$fs_cmd_logs" | fs_parse_stat | awk -F'\t' 'index($2, "/sdcard/MIUI/debug_log/") == 1' | fs_unseen >"$TMPD/fs_c_logs"
  fs_offer_delete "$TMPD/fs_c_logs" "MIUI debug logs (MIUI/debug_log)" "file" \
    "Error reports MIUI writes for itself. The phone does not need them to work."
}

fs_step_junk() {
  : >"$TMPD/fs_seen"
  echo
  echo "== Step 3: hidden junk =="
  echo "  Each kind is shown first and deleted only if you type y for it."
  echo "  Deleting is permanent, so you can copy the files to this computer first and put them back later."
  echo "  Looking around (this can take a minute)..."
  fs_junk_trash
  fs_junk_miui_bin
  fs_junk_apks
  fs_junk_wa
  fs_junk_leftovers
  fs_junk_logs
}

fs_summary() {
  local now_df=$1 start_df=$2
  echo
  echo "== Summary =="
  [ -z "$fs_trim_freed" ] || echo "  Temporary cache cleared: $(fs_hum "$fs_trim_freed") came back."
  if [ "$fs_freed_total" -gt 0 ]; then
    echo "  Hidden junk deleted: $(fs_hum "$fs_freed_total")."
    echo "  A list of everything deleted is in $fs_log"
  else
    echo "  No junk was deleted."
  fi
  if [ -n "$now_df" ]; then
    set -- $now_df
    if [ -n "$start_df" ]; then
      echo "  Free space now: $(fs_hum $(($3 * 1024))) of $(fs_hum $(($1 * 1024)))   (was $(fs_hum $(($(echo "$start_df" | awk '{ print $3 }') * 1024))) at the start)."
    else
      echo "  Free space now: $(fs_hum $(($3 * 1024))) of $(fs_hum $(($1 * 1024)))."
    fi
  fi
  if [ "$fs_copied" = 1 ]; then
    echo "  Copies of deleted files: $(pwd)/$fs_junk_dir"
    echo "  To put them back on the phone, choose this option again and answer y to the first question."
  fi
}

free_space() {
  local before
  fs_junk_dir="phone-junk-$(date +%Y%m%d)"
  fs_freed_total=0
  fs_trim_freed=""
  fs_copied=0
  fs_notes=""
  echo "== Free up space =="
  echo "Nothing is changed or deleted unless you type y. Just pressing Enter means No."
  fs_offer_restore
  echo
  echo "== Storage right now =="
  before=$(fs_df)
  fs_show_df "$before"
  ash "$fs_cmd_disk" >"$TMPD/fs_disk" 2>/dev/null
  fs_step_cache "$before"
  fs_step_report
  fs_step_junk
  fs_summary "$(fs_df)" "$before"
}
