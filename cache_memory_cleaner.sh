#!/usr/bin/env bash
# cache_memory_cleaner.sh — macOS cache/storage cleanup, distilled from a real
# disk-space recovery session. Only touches regenerable caches and dormant
# tools; never touches live databases, session data, or files it can't prove
# are safe to remove.
#
# Usage:
#   ./cache_memory_cleaner.sh report          # show disk usage + what's found, no changes
#   ./cache_memory_cleaner.sh clean-caches     # clear browser/package-manager caches
#   ./cache_memory_cleaner.sh clean-packages   # brew autoremove/cleanup, npm/pip/gem cache
#   ./cache_memory_cleaner.sh find-dormant     # report (not remove) unused brew formulae/casks
#   ./cache_memory_cleaner.sh git-gc [path]    # compact a git repo's objects (safe, reachability-based)
#   ./cache_memory_cleaner.sh archive-evict <path> [name]  # archive to cloud, verify, THEN delete
#   ./cache_memory_cleaner.sh list-archives   # show everything archive-evict has sent to the cloud
#   ./cache_memory_cleaner.sh compress-local <path> [<path>...]  # transparent HFS/APFS compression
#   ./cache_memory_cleaner.sh all              # report + clean-caches + clean-packages
#
# Design principles learned the hard way in the session this was built from:
#   - Never delete a live database's data directory or a running app's active
#     state (e.g. an in-use sandbox/VM bundle) — check what's actually running
#     before touching anything under Application Support or a service's data dir.
#   - `git gc` is safe regardless of push status: it compacts reachable objects,
#     it does not delete branch history. It will NOT reclaim space from branches
#     that were deleted without merging — that's a human decision, not this tool's.
#   - Many-small-files directories (LFS-style datasets, thousands of parquet/xml
#     files) upload/delete catastrophically slowly against cloud APIs (Dropbox,
#     Google Drive) compared to one large archive. If you're archiving something
#     before deleting it locally, tar it first.
#   - "Verify then evict": never delete a local copy of data because you *think*
#     it's backed up — check the remote copy's byte size matches before removing
#     anything that isn't trivially re-creatable.
#   - PEP 668 (externally-managed-environment) blocks direct `pip install` on
#     Homebrew's Python; packages already living in the protected site-packages
#     need `--break-system-packages` to upgrade in place — same method they were
#     originally installed with.
#   - A brew formula/cask registered as "installed" can already be a "ghost" if
#     its .app was deleted by hand outside of brew — check /Applications (via
#     `brew info --cask <name>` for the real app name) before assuming an
#     installed cask corresponds to a live app.
#   - A configured VM (Podman machine, Docker Desktop's VM, etc.) that shows
#     "Last Up: Never" is disk allocated for something that was set up but never
#     actually used — safe to remove.
set -uo pipefail

DRY_RUN="${DRY_RUN:-0}"   # DRY_RUN=1 ./cache_memory_cleaner.sh clean-caches -- report without deleting

log() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] $*"
  else
    eval "$@"
  fi
}
free_gb() { df -g / 2>/dev/null | awk 'NR==2 {print $4}'; }

# ── report ────────────────────────────────────────────────────────────────
cmd_report() {
  log "=== Disk usage ==="
  df -h / 2>/dev/null
  log
  log "=== Top-level home directory usage (du can take a while) ==="
  du -sh "$HOME"/*/ "$HOME"/.[a-zA-Z]*/ 2>/dev/null | sort -rh | head -20
}

# ── clean-caches ─────────────────────────────────────────────────────────
# Only touches directories that are provably regenerable: browser render/JS
# caches, package-manager download caches. Leaves IndexedDB, Extensions,
# Local Storage, and profile data alone — those can hold real user data.
cmd_clean_caches() {
  local before after
  before=$(free_gb)

  log "=== Browser caches (Library/Caches — safe, apps rebuild on demand) ==="
  for b in Google BraveSoftware Firefox com.brave.Browser; do
    p="$HOME/Library/Caches/$b"
    [ -d "$p" ] && run "rm -rf '$p'"
  done

  log "=== Chrome's redownloadable on-device ML model caches ==="
  local chrome="$HOME/Library/Application Support/Google/Chrome"
  for d in OptGuideOnDeviceModel screen_ai optimization_guide_model_store component_crx_cache; do
    p="$chrome/$d"
    [ -d "$p" ] && run "rm -rf '$p'"
  done

  log "=== Chrome Service Worker + GPUCache across all profiles (not IndexedDB/Extensions) ==="
  if [ -d "$chrome" ]; then
    for prof in "$chrome"/*/; do
      for sub in "Service Worker" "GPUCache"; do
        p="${prof%/}/$sub"
        [ -d "$p" ] && run "rm -rf '$p'"
      done
    done
  fi

  log "=== Package-manager caches ==="
  [ -d "$HOME/Library/Caches/Homebrew" ] && run "rm -rf '$HOME/Library/Caches/Homebrew'"
  [ -d "$HOME/Library/Caches/pip" ] && run "rm -rf '$HOME/Library/Caches/pip'"
  [ -d "$HOME/.npm" ] && run "rm -rf '$HOME/.npm'"
  [ -d "$HOME/.cache/uv" ] && run "rm -rf '$HOME/.cache/uv'"
  [ -d "$HOME/.cache/gem" ] && run "rm -rf '$HOME/.cache/gem'"

  after=$(free_gb)
  log
  log "Free space: ${before}GB -> ${after}GB"
}

# ── clean-packages ───────────────────────────────────────────────────────
cmd_clean_packages() {
  if command -v brew >/dev/null 2>&1; then
    log "=== brew: autoremove orphaned deps + cleanup old versions/cache ==="
    run "brew autoremove"
    run "brew cleanup -s"
  fi
  if command -v npm >/dev/null 2>&1; then
    log "=== npm: prune global cache ==="
    run "npm cache clean --force"
  fi
}

# ── trim-vms ──────────────────────────────────────────────────────────────
# Container/VM disk images (Podman, similar tools) are sparse files on the
# host, but pruning images/volumes INSIDE the VM does not shrink the host
# file — the guest OS marks blocks free, but nothing tells the host-side
# sparse file to release them. `fstrim` inside the VM issues the actual
# discard, which the host sparse file then honors. Learned from a real case:
# a Podman VM's host footprint didn't move after `system prune` freed 1.76GB
# inside it; `fstrim -av` over SSH dropped the host file from 10G to 2G with
# the machine still fully usable afterward.
cmd_trim_vms() {
  if command -v podman >/dev/null 2>&1 && podman machine list --format "{{.Name}}" 2>/dev/null | grep -q .; then
    log "=== podman: prune unused images/volumes, then fstrim to reclaim host disk ==="
    run "podman machine start"
    run "podman system prune -a --volumes -f"
    run 'podman machine ssh "sudo fstrim -av"'
    run "podman machine stop"
  else
    log "no podman machine found, skipping"
  fi
}

# ── find-dormant ─────────────────────────────────────────────────────────
# Report-only: never auto-removes. Flags brew leaves and Application
# Support directories with zero file modifications in the last N days as
# candidates for the human to review, plus any cask whose app is missing.
cmd_find_dormant() {
  local days="${1:-30}"
  if command -v brew >/dev/null 2>&1; then
    log "=== brew leaves (top-level installs; each still needs individual judgment) ==="
    brew leaves 2>&1

    log
    log "=== Casks whose .app is missing from /Applications (ghost installs) ==="
    for c in $(brew list --cask 2>/dev/null); do
      app=$(brew info --cask "$c" 2>/dev/null | grep -oE '[^ ]+\.app \(App\)' | head -1 | sed 's/ (App)//')
      if [ -n "$app" ] && [ ! -e "/Applications/$app" ]; then
        echo "  $c -> /Applications/$app MISSING"
      fi
    done
  fi

  log
  log "=== Application Support dirs with zero activity in ${days} days ==="
  find "$HOME/Library/Application Support" -maxdepth 1 -type d 2>/dev/null | while read -r d; do
    [ "$d" = "$HOME/Library/Application Support" ] && continue
    recent=$(find "$d" -type f -newermt "-${days} days" 2>/dev/null | head -1)
    [ -z "$recent" ] && echo "  $(basename "$d")  ($(du -sh "$d" 2>/dev/null | cut -f1))"
  done

  if command -v podman >/dev/null 2>&1; then
    log
    log "=== Podman machines that have never been started ==="
    podman machine list --format "{{.Name}} {{.LastUp}}" 2>/dev/null | grep -i "never" || echo "  none found"
  fi
}

# ── git-gc ────────────────────────────────────────────────────────────────
# Safe regardless of push status (operates on reachability, not remote
# state) — but warns about branches with no upstream or with unpushed work,
# since THAT is a human decision (push, delete, or accept the risk), not
# something this tool should decide.
cmd_git_gc() {
  local repo="${1:-.}"
  ( cd "$repo" || exit 1
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      log "not a git repo: $repo"; exit 1
    fi
    log "=== Branches with no upstream (commits exist ONLY locally) ==="
    for b in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
      git rev-parse --abbrev-ref "$b@{upstream}" >/dev/null 2>&1 || echo "  $b"
    done
    log
    before=$(du -sh .git 2>/dev/null | cut -f1)
    log "=== Running git gc (.git currently: $before) ==="
    run "git gc --prune=now"
    after=$(du -sh .git 2>/dev/null | cut -f1)
    log ".git: $before -> $after"
  )
}

# ── archive-evict ────────────────────────────────────────────────────────
# Generalizes the "verify then evict" pattern used throughout every real
# cleanup session this tool is built from: tar+zstd a directory, upload it to
# every configured cloud remote, byte-verify EACH upload against the local
# archive, and only delete the original (+ the local archive copy) once every
# remote is confirmed. If any remote fails, BOTH copies are kept — same
# fail-safe a nightly backup script uses, generalized to any one-off path
# instead of a fixed dataset list. Every successful archive is logged to
# $ARCHIVE_LOG so "what did I move to the cloud and where" stays answerable
# months later — the whole point of moving something instead of just rm -rf'ing
# it.
#
# Configure destinations with CLEANER_REMOTES (space-separated rclone dest
# paths, e.g. CLEANER_REMOTES="dropbox:cache-archives googledrive:cache-archives").
# Falls back to "dropbox:cache-archives" if a `dropbox:` remote exists and
# CLEANER_REMOTES is unset. Requires rclone.
#
# 🔴 NEVER point CLEANER_REMOTES at a path some OTHER job mirrors with
# `rclone sync` (delete-what's-not-local semantics) from a local directory —
# e.g. a nightly backup script that syncs ~/some-local-dir to that same
# remote path. This function's whole point is to upload something and then
# delete the LOCAL copy; if a sync job later mirrors its (now smaller) local
# source onto the same remote folder, it will delete what you just archived
# to make the remote match. Lost this exact way once: four archives verified
# uploaded, then wiped by an unrelated nightly `rclone sync --delete-excluded`
# that happened to target the same destination folder for a different
# purpose. Use a destination path nothing else writes to, ever.
ARCHIVE_STAGING="${ARCHIVE_STAGING:-$HOME/.cache_memory_cleaner/archives}"
ARCHIVE_LOG="${ARCHIVE_LOG:-$HOME/.cache_memory_cleaner/archive_log.tsv}"

cmd_archive_evict() {
  local path="$1" name="$2"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    log "usage: $0 archive-evict <path> [archive-name]"
    log "  Archives <path> to \$ARCHIVE_STAGING, uploads it to every remote in"
    log "  \$CLEANER_REMOTES, byte-verifies each, and ONLY THEN deletes the"
    log "  original path and the local archive copy. Keeps both if any remote"
    log "  fails verification."
    return 1
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    log "rclone not found — install it to use archive-evict."
    return 1
  fi

  path="${path%/}"
  [ -z "$name" ] && name="$(basename "$path")-$(date +%Y%m%d)"

  local remotes="${CLEANER_REMOTES:-}"
  if [ -z "$remotes" ] && rclone listremotes 2>/dev/null | grep -q '^dropbox:$'; then
    remotes="dropbox:cache-archives"
  fi
  if [ -z "$remotes" ]; then
    log "No destination configured. Set CLEANER_REMOTES=\"dropbox:some/path googledrive:some/path\""
    log "(any rclone remote:path works) and retry."
    return 1
  fi

  mkdir -p "$ARCHIVE_STAGING" "$(dirname "$ARCHIVE_LOG")"
  local archive="$ARCHIVE_STAGING/${name}.tar.zst"
  log "=== Archiving $path -> $archive ==="
  run "tar -cf - -C '$(dirname "$path")' '$(basename "$path")' | zstd -T0 -19 -o '$archive'"

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would upload $archive to: $remotes"
    log "[dry-run] would byte-verify each, then delete $path and $archive only if all verify"
    return 0
  fi

  local local_size all_ok=1 rem remote_size
  local_size=$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive" 2>/dev/null)
  for rem in $remotes; do
    log "=== Uploading to $rem ==="
    if ! rclone copy "$archive" "$rem" --log-level ERROR; then
      log "FAIL upload -> $rem"; all_ok=0; continue
    fi
    remote_size=$(rclone size "$rem/$(basename "$archive")" --json 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['bytes'])" 2>/dev/null || echo -1)
    if [ "$local_size" = "$remote_size" ]; then
      log "OK   verified on $rem ($remote_size bytes)"
    else
      log "FAIL verify on $rem (local=$local_size remote=$remote_size)"
      all_ok=0
    fi
  done

  if [ "$all_ok" = 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$(basename "$archive")" "$local_size" "$remotes" \
      >> "$ARCHIVE_LOG"
    run "rm -rf '$path'"
    run "rm -f '$archive'"
    log "OK   $path archived + verified on all remotes; local copies removed."
    log "     Logged to $ARCHIVE_LOG — run '$0 list-archives' to see everything archived this way."
  else
    log "KEPT $path and $archive locally (one or more remotes unverified) — nothing deleted."
  fi
}

# ── list-archives ────────────────────────────────────────────────────────
cmd_list_archives() {
  if [ ! -f "$ARCHIVE_LOG" ]; then
    log "No archives recorded yet ($ARCHIVE_LOG doesn't exist)."
    return 0
  fi
  log "=== Everything archive-evict has moved to the cloud ==="
  log "$(printf '%-20s %-45s %-30s %10s  %s' DATE ORIGINAL-PATH ARCHIVE-NAME BYTES REMOTES)"
  while IFS=$'\t' read -r date_ orig archive bytes remotes; do
    printf '%-20s %-45s %-30s %10s  %s\n' "$date_" "$orig" "$archive" "$bytes" "$remotes"
  done < "$ARCHIVE_LOG"
}

# ── compress-local ───────────────────────────────────────────────────────
# For data that has to stay local (a live pipeline's working set, a repo's
# own reports/, an actively-read cache) rather than being archived away:
# macOS's native HFS+/APFS transparent compression (decmpfs) shrinks files on
# disk with ZERO workflow change — every reader (a text editor, `cat`, Python
# reading a venv's site-packages, a JSON.load(), grep) gets the same bytes
# back automatically, no unzip step, no decompression code anywhere. This is
# NOT gzip: the file's name, extension, and apparent content are unchanged;
# only the on-disk storage is smaller. Measured on real data: a Python venv
# 209M -> 92M (56% smaller) still executed correctly afterward; a JSON
# knowledge-graph file 123M -> 6.2M (95% smaller) round-tripped through
# json.load() byte-identical; a directory of 400 CSV/Markdown report files
# 60M -> 16M (72.8% smaller).
#
# `ditto --hfsCompression` (built into macOS) is NOT reliable for this on
# recent macOS versions — it silently no-ops on non-Apple content without
# error. Use `afsctool` instead (`brew install afsctool`), which actually
# applies and verifies the compression.
#
# Best candidates: plain text and structured text (source code, CSV, JSON,
# Markdown, logs, XML) — often 50-95% smaller. Skip already-compressed
# formats (JPEG/PNG, MP4, ZIP-based Office docs, .git objects, parquet) —
# afsctool tries and skips them automatically when compression doesn't help,
# but running it there just burns CPU for nothing.
#
# Safe to run repeatedly (idempotent — already-compressed files are
# re-verified, not re-compressed) and safe on live/actively-read data: a
# reader never sees a "compressing" state, only complete files.
cmd_compress_local() {
  if [ $# -eq 0 ]; then
    log "usage: $0 compress-local <path> [<path>...]"
    log "  Applies transparent HFS/APFS compression (via afsctool) to each path."
    log "  Files stay fully readable/writable by any program — only disk usage shrinks."
    return 1
  fi
  if ! command -v afsctool >/dev/null 2>&1; then
    log "afsctool not found. Install it: brew install afsctool"
    return 1
  fi
  local p before after
  for p in "$@"; do
    if [ ! -e "$p" ]; then
      log "skip (not found): $p"
      continue
    fi
    before=$(du -sh "$p" 2>/dev/null | cut -f1)
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry-run] afsctool -c '$p'"
      continue
    fi
    afsctool -c "$p" 2>&1 | grep -v "^$" | sed 's/^/  /'
    after=$(du -sh "$p" 2>/dev/null | cut -f1)
    log "$p: $before -> $after"
  done
}

case "${1:-}" in
  report)        cmd_report ;;
  clean-caches)  cmd_clean_caches ;;
  clean-packages) cmd_clean_packages ;;
  find-dormant)  cmd_find_dormant "${2:-30}" ;;
  git-gc)        cmd_git_gc "${2:-.}" ;;
  trim-vms)      cmd_trim_vms ;;
  archive-evict) cmd_archive_evict "${2:-}" "${3:-}" ;;
  list-archives) cmd_list_archives ;;
  compress-local) shift; cmd_compress_local "$@" ;;
  all)
    cmd_report
    echo
    cmd_clean_caches
    echo
    cmd_clean_packages
    echo
    cmd_trim_vms
    ;;
  *)
    echo "Usage: $0 {report|clean-caches|clean-packages|find-dormant [days]|git-gc [path]|archive-evict <path> [name]|list-archives|compress-local <path> [<path>...]|trim-vms|all}"
    echo "Set DRY_RUN=1 to preview without deleting anything."
    exit 1
    ;;
esac
