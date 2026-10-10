#!/usr/bin/env bash
# Every 5 minutes: copy in-progress work into the repo and push it if anything changed.
S=/tmp/claude-0/-home-user-CL-CDEXP/667de52e-432d-553c-802c-a79fc447d05b/scratchpad
R=/home/user/CL_CDEXP
while true; do
  sleep 300
  rm -rf "$R/tools/wip/features" "$R/tools/wip/harness" && mkdir -p "$R/tools/wip"
  cp -r "$S/features" "$S/harness" "$R/tools/wip/" 2>/dev/null
  find "$R/tools/wip" -type d \( -name tmp -o -name review-tmp -o -name .work \) -prune -exec rm -rf {} + 2>/dev/null
  find "$R/tools/wip" -type f -size +5M -delete 2>/dev/null
  [ -f "$S/GUIDE.md" ] && cp "$S/GUIDE.md" "$R/tools/wip/GUIDE.md"
  [ -d "$S/tests-main" ] && rm -rf "$R/tools/wip/tests-main" && cp -r "$S/tests-main" "$R/tools/wip/" \
    && find "$R/tools/wip/tests-main" -type d -name tmp -prune -exec rm -rf {} + 2>/dev/null
  cd "$R" || continue
  git add -A tools .gitignore >/dev/null 2>&1
  if ! git diff --cached --quiet; then
    git commit -q -m "Autosave work in progress ($(date -u +%H:%M) UTC)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PAFTqYewPX7P3tA1cEUvyZ" \
      && { ok=0; for i in 1 2 3; do git push -q origin claude/mobile-optimization-advice-kcgr80 && { ok=1; break; }; sleep $((i*4)); done
           [ $ok = 1 ] && echo "autosaved $(date -u +%H:%M)" || echo "AUTOSAVE PUSH FAILED $(date -u +%H:%M)"; }
  fi
done
