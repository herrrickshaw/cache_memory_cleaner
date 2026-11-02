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
#   ./cache_memory_cleaner.sh trim-vms         # prune + fstrim Podman VM disk images
#   ./cache_memory_cleaner.sh archive-evict <path> [name]  # archive to cloud, verify, THEN delete
#   ./cache_memory_cleaner.sh list-archives   # show everything archive-evict has sent to the cloud
#   ./cache_memory_cleaner.sh compress-local <path> [<path>...]  # transparent HFS/APFS compression
#   ./cache_memory_cleaner.sh classify <path>  # recommend a data tier for <path> (read-only, decides nothing)
#   ./cache_memory_cleaner.sh all              # report + clean-caches + clean-packages + trim-vms
#
# Set DRY_RUN=1 to print every mutating command instead of running it.
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
#
# Shell options: `-u` and `pipefail` only. `-e` is deliberately NOT set — the
# script relies on non-zero statuses as data (grep -q probes, `[ -d ] && run`,
# optional tools missing, a `git rev-parse` that fails for a branch with no
# upstream), so `-e` would abort healthy runs. Must stay bash-3.2 compatible
# (macOS /bin/bash): no associative arrays, no `mapfile`.
set -uo pipefail

# ── configuration (environment-overridable) ──────────────────────────────
DRY_RUN="${DRY_RUN:-0}"   # DRY_RUN=1 ./cache_memory_cleaner.sh clean-caches -- report without deleting
ARCHIVE_STAGING="${ARCHIVE_STAGING:-$HOME/.cache_memory_cleaner/archives}"
ARCHIVE_LOG="${ARCHIVE_LOG:-$HOME/.cache_memory_cleaner/archive_log.tsv}"
# CLEANER_REMOTES: space-separated rclone dest paths for archive-evict,
# e.g. "dropbox:cache-archives googledrive:cache-archives". See cmd_archive_evict.

# ── constants ────────────────────────────────────────────────────────────
readonly DEFAULT_REMOTE="dropbox:cache-archives"   # used when CLEANER_REMOTES is unset and a dropbox: remote exists
readonly FIND_DORMANT_DEFAULT_DAYS=30
readonly SECONDS_PER_DAY=86400
readonly TIER1_ACTIVE_DAYS=7        # git-tracked + modified within this → Tier 1 (compress in place)
readonly TIER3_DORMANT_DAYS=14      # untracked + untouched for this long → Tier 3 (archive, then evict)
readonly MANY_FILES_THRESHOLD=500   # above this, a dormant dir is flagged as a recurring raw-cache shape

# Regenerable-on-demand browser caches under ~/Library/Caches.
BROWSER_CACHE_DIRS=(Google BraveSoftware Firefox com.brave.Browser)
# Chrome's redownloadable on-device ML model caches under its Application Support dir.
CHROME_MODEL_CACHE_DIRS=(OptGuideOnDeviceModel screen_ai optimization_guide_model_store component_crx_cache)
# Per-profile Chrome caches that are safe to drop (NOT IndexedDB/Extensions/Local Storage).
CHROME_PROFILE_CACHE_DIRS=("Service Worker" GPUCache)
# Package-manager download caches, relative to $HOME.
PACKAGE_CACHE_DIRS=(Library/Caches/Homebrew Library/Caches/pip .npm .cache/uv .cache/gem)

# Filename fragments (lower-case) that mark a personal / scanned document → Tier 0.
PERSONAL_DOC_KEYWORDS="certificate receipt statement declaration agreement license licence loan aadhaar aadhar pan_card passport affidavit rti_reply transaction_statement payslip pay_slip form- kyc identity voter ration_card"

# ── helpers ──────────────────────────────────────────────────────────────
log() { printf '%s\n' "$*"; }
yes_no() { [ "$1" = 1 ] && echo yes || echo no; }
free_gb() { df -g / 2>/dev/null | awk 'NR==2 {print $4}'; }
dir_size() { du -sh "$1" 2>/dev/null | cut -f1; }
file_size_bytes() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }
is_dry_run() { [ "$DRY_RUN" = "1" ]; }

# run <cmd> [args...] — execute argv, or log it when DRY_RUN=1. Never eval.
run() {
  if is_dry_run; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}
# run_shown <shown> <cmd> [args...] — like run, but the dry-run line prints
# <shown> (for commands whose historical dry-run line carried shell quoting).
run_shown() {
  local shown="$1"; shift
  if is_dry_run; then
    log "[dry-run] $shown"
  else
    "$@"
  fi
}
run_rm_rf() { run_shown "rm -rf '$1'" rm -rf -- "$1"; }
run_rm_f()  { run_shown "rm -f '$1'"  rm -f  -- "$1"; }

usage() {
  echo "Usage: $0 {report|clean-caches|clean-packages|find-dormant [days]|git-gc [path]|archive-evict <path> [name]|list-archives|compress-local <path> [<path>...]|classify <path>|trim-vms|all}"
  echo "Set DRY_RUN=1 to preview without deleting anything."
}

# branches_without_upstream <repo> — one local branch per line that has no
# upstream (its commits exist nowhere but this disk).
branches_without_upstream() {
  local repo="$1" b
  git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | while read -r b; do
    git -C "$repo" rev-parse --abbrev-ref "$b@{upstream}" >/dev/null 2>&1 || echo "$b"
  done
}

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
  local before after p d prof sub
  before=$(free_gb)

  log "=== Browser caches (Library/Caches — safe, apps rebuild on demand) ==="
  for d in "${BROWSER_CACHE_DIRS[@]}"; do
    p="$HOME/Library/Caches/$d"
    [ -d "$p" ] && run_rm_rf "$p"
  done

  log "=== Chrome's redownloadable on-device ML model caches ==="
  local chrome="$HOME/Library/Application Support/Google/Chrome"
  for d in "${CHROME_MODEL_CACHE_DIRS[@]}"; do
    p="$chrome/$d"
    [ -d "$p" ] && run_rm_rf "$p"
  done

  log "=== Chrome Service Worker + GPUCache across all profiles (not IndexedDB/Extensions) ==="
  if [ -d "$chrome" ]; then
    for prof in "$chrome"/*/; do
      for sub in "${CHROME_PROFILE_CACHE_DIRS[@]}"; do
        p="${prof%/}/$sub"
        [ -d "$p" ] && run_rm_rf "$p"
      done
    done
  fi

  log "=== Package-manager caches ==="
  for d in "${PACKAGE_CACHE_DIRS[@]}"; do
    p="$HOME/$d"
    [ -d "$p" ] && run_rm_rf "$p"
  done

  after=$(free_gb)
  log
  log "Free space: ${before}GB -> ${after}GB"
}

# ── clean-packages ───────────────────────────────────────────────────────
cmd_clean_packages() {
  if command -v brew >/dev/null 2>&1; then
    log "=== brew: autoremove orphaned deps + cleanup old versions/cache ==="
    run brew autoremove
    run brew cleanup -s
  fi
  if command -v npm >/dev/null 2>&1; then
    log "=== npm: prune global cache ==="
    run npm cache clean --force
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
    run podman machine start
    run podman system prune -a --volumes -f
    run_shown 'podman machine ssh "sudo fstrim -av"' podman machine ssh "sudo fstrim -av"
    run podman machine stop
  else
    log "no podman machine found, skipping"
  fi
}

# ── find-dormant ─────────────────────────────────────────────────────────
# Report-only: never auto-removes. Flags brew leaves and Application
# Support directories with zero file modifications in the last N days as
# candidates for the human to review, plus any cask whose app is missing.
report_ghost_casks() {
  local c app
  for c in $(brew list --cask 2>/dev/null); do
    app=$(brew info --cask "$c" 2>/dev/null | grep -oE '[^ ]+\.app \(App\)' | head -1 | sed 's/ (App)//')
    if [ -n "$app" ] && [ ! -e "/Applications/$app" ]; then
      echo "  $c -> /Applications/$app MISSING"
    fi
  done
}

report_idle_app_support_dirs() {
  local days="$1" root="$HOME/Library/Application Support" d recent
  find "$root" -maxdepth 1 -type d 2>/dev/null | while read -r d; do
    [ "$d" = "$root" ] && continue
    recent=$(find "$d" -type f -newermt "-${days} days" 2>/dev/null | head -1)
    [ -z "$recent" ] && echo "  $(basename "$d")  ($(dir_size "$d"))"
  done
}

cmd_find_dormant() {
  local days="${1:-$FIND_DORMANT_DEFAULT_DAYS}"
  if command -v brew >/dev/null 2>&1; then
    log "=== brew leaves (top-level installs; each still needs individual judgment) ==="
    brew leaves 2>&1

    log
    log "=== Casks whose .app is missing from /Applications (ghost installs) ==="
    report_ghost_casks
  fi

  log
  log "=== Application Support dirs with zero activity in ${days} days ==="
  report_idle_app_support_dirs "$days"

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
    branches_without_upstream . | sed 's/^/  /'
    log
    before=$(dir_size .git)
    log "=== Running git gc (.git currently: $before) ==="
    run git gc --prune=now
    after=$(dir_size .git)
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

# archive_remotes — print the configured remotes, or nothing if none resolve.
archive_remotes() {
  local remotes="${CLEANER_REMOTES:-}"
  if [ -z "$remotes" ] && rclone listremotes 2>/dev/null | grep -q '^dropbox:$'; then
    remotes="$DEFAULT_REMOTE"
  fi
  printf '%s' "$remotes"
}

# archive_create <path> <archive> — tar+zstd <path> into <archive>.
archive_create() {
  local path="$1" archive="$2" parent base
  parent=$(dirname "$path"); base=$(basename "$path")
  if is_dry_run; then
    log "[dry-run] tar -cf - -C '$parent' '$base' | zstd -T0 -19 -o '$archive'"
  else
    tar -cf - -C "$parent" "$base" | zstd -T0 -19 -o "$archive"
  fi
}

# remote_size_bytes <remote-file> — byte size reported by rclone, or -1.
remote_size_bytes() {
  rclone size "$1" --json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['bytes'])" 2>/dev/null || echo -1
}

# archive_upload_verify <archive> <local_size> <remotes> — upload to every
# remote and byte-verify each. Returns 0 only if ALL remotes verified.
archive_upload_verify() {
  local archive="$1" local_size="$2" remotes="$3" all_ok=1 rem remote_size
  for rem in $remotes; do
    log "=== Uploading to $rem ==="
    if ! rclone copy "$archive" "$rem" --log-level ERROR; then
      log "FAIL upload -> $rem"; all_ok=0; continue
    fi
    remote_size=$(remote_size_bytes "$rem/$(basename "$archive")")
    if [ "$local_size" = "$remote_size" ]; then
      log "OK   verified on $rem ($remote_size bytes)"
    else
      log "FAIL verify on $rem (local=$local_size remote=$remote_size)"
      all_ok=0
    fi
  done
  [ "$all_ok" = 1 ]
}

# archive_record <path> <archive> <bytes> <remotes> — append one TSV row to $ARCHIVE_LOG.
archive_record() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(basename "$2")" "$3" "$4" \
    >> "$ARCHIVE_LOG"
}

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

  local remotes
  remotes=$(archive_remotes)
  if [ -z "$remotes" ]; then
    log "No destination configured. Set CLEANER_REMOTES=\"dropbox:some/path googledrive:some/path\""
    log "(any rclone remote:path works) and retry."
    return 1
  fi

  mkdir -p "$ARCHIVE_STAGING" "$(dirname "$ARCHIVE_LOG")"
  local archive="$ARCHIVE_STAGING/${name}.tar.zst"
  log "=== Archiving $path -> $archive ==="
  archive_create "$path" "$archive"

  if is_dry_run; then
    log "[dry-run] would upload $archive to: $remotes"
    log "[dry-run] would byte-verify each, then delete $path and $archive only if all verify"
    return 0
  fi

  local local_size
  local_size=$(file_size_bytes "$archive")
  if archive_upload_verify "$archive" "$local_size" "$remotes"; then
    archive_record "$path" "$archive" "$local_size" "$remotes"
    run_rm_rf "$path"
    run_rm_f "$archive"
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
  local date_ orig archive bytes remotes
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
compress_one() {
  local p="$1" before after
  if [ ! -e "$p" ]; then
    log "skip (not found): $p"
    return 0
  fi
  before=$(dir_size "$p")
  if is_dry_run; then
    log "[dry-run] afsctool -c '$p'"
    return 0
  fi
  afsctool -c "$p" 2>&1 | grep -v "^$" | sed 's/^/  /'
  after=$(dir_size "$p")
  log "$p: $before -> $after"
}

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
  local p
  for p in "$@"; do
    compress_one "$p"
  done
}

# ── classify ─────────────────────────────────────────────────────────────
# Applies the decision tree from DATA_TIER_POLICY.md to one path and prints a
# recommended tier + the specific reason. READ-ONLY: it never deletes, moves,
# compresses, or uploads anything — it's decision support, not an executor.
# The tiers (see the policy doc for the full reasoning and real examples):
#   0  Never touch programmatically   - live app state, personal/scanned docs,
#                                       GUI-only settings, another process's
#                                       open files
#   1  Permanent local, compress      - actively read directly by a script/app,
#                                       but transparent HFS compression is free
#   2  Cloud-backed, keep local       - git-tracked (redundant via GitHub), or
#                                       active non-personal working files
#   3  Archive to cloud, then evict   - dormant, untracked, not read directly
#   4  Delete immediately, no backup  - reproducible from a package manager or
#                                       build step in seconds
#   ?  Needs manual judgment          - signals are printed; decide by hand
#
# Each signal below is a small pure function of the absolute path: predicates
# return 0/1 via exit status, value signals print to stdout.

# Is anything running with this path in its argv right now?
# (static ps snapshot, never a live self-matching grep in a loop)
sig_live_process() {
  local ps_snapshot
  ps_snapshot=$(ps aux 2>/dev/null | grep -v "grep\|cache_memory_cleaner.sh")
  echo "$ps_snapshot" | grep -qF "$1"
}

# Personal/scanned-document filename pattern (case-insensitive) or path.
sig_personal_doc() {
  local abspath="$1" base_lower kw
  base_lower=$(basename "$abspath" | tr '[:upper:]' '[:lower:]')
  for kw in $PERSONAL_DOC_KEYWORDS; do
    case "$base_lower" in *"$kw"*) return 0 ;; esac
  done
  case "$abspath" in *"/Documents/personal-archive/"*) return 0 ;; esac
  return 1
}

# Vendor-managed cloud sync mirror (Dropbox/GDrive local folder).
sig_in_cloudstorage() {
  case "$1" in "$HOME/Library/CloudStorage/"*) return 0 ;; esac
  return 1
}

# Git toplevel containing the path (empty if none).
sig_git_root() {
  local dir="$1"
  [ -f "$dir" ] && dir="$(dirname "$dir")"
  (cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
}
git_is_tracked() { git -C "$1" ls-files --error-unmatch "$2" >/dev/null 2>&1; }
git_is_ignored() { git -C "$1" check-ignore -q "$2" 2>/dev/null; }
git_has_remote() { [ -n "$(git -C "$1" remote 2>/dev/null)" ]; }

# Days since the most recently modified file inside (or the file itself), or "unknown".
sig_days_dormant() {
  local abspath="$1" newest_epoch
  newest_epoch=$(find "$abspath" -type f -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1)
  if [ -z "$newest_epoch" ] && [ -f "$abspath" ]; then
    newest_epoch=$(stat -f '%m' "$abspath" 2>/dev/null)
  fi
  if [ -n "$newest_epoch" ]; then
    echo $(( ( $(date +%s) - newest_epoch ) / SECONDS_PER_DAY ))
  else
    echo unknown
  fi
}

sig_is_venv() { [ -f "$1/bin/activate" ] || [ -f "$1/pyvenv.cfg" ]; }

# Pure-cache name pattern (regenerates from a package manager/build step).
sig_pure_cache_name() {
  case "$(basename "$1")" in
    __pycache__|.pytest_cache|node_modules|.npm|Homebrew|.gem|_npx) return 0 ;;
  esac
  return 1
}

# Many-small-files raw-cache shape (thousands of files, no single dominant
# blob) - a hint this belongs in datasets.conf/STATIC_SUBDIRS rather than a
# one-off archive-evict.
sig_file_count() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

cmd_classify() {
  local path="${1:-}"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    log "usage: $0 classify <path>"
    return 1
  fi
  path="${path%/}"
  local abspath
  abspath=$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")
  log "=== Classifying: $abspath ==="

  local live_process=0 personal_match=0 in_cloudstorage=0 is_venv=0 pure_cache_name=0
  sig_live_process "$abspath"    && live_process=1
  sig_personal_doc "$abspath"    && personal_match=1
  sig_in_cloudstorage "$abspath" && in_cloudstorage=1
  sig_is_venv "$abspath"         && is_venv=1
  sig_pure_cache_name "$abspath" && pure_cache_name=1

  local git_root git_tracked=0 git_ignored=0 has_remote=0 relpath
  git_root=$(sig_git_root "$abspath")
  if [ -n "$git_root" ]; then
    relpath="${abspath#"$git_root"/}"
    git_is_tracked "$git_root" "$relpath" && git_tracked=1
    git_is_ignored "$git_root" "$relpath" && git_ignored=1
    git_has_remote "$git_root"            && has_remote=1
  fi

  local no_upstream_branches=""
  [ -d "$abspath/.git" ] && no_upstream_branches=$(branches_without_upstream "$abspath")

  local days_dormant file_count
  days_dormant=$(sig_days_dormant "$abspath")
  file_count=$(sig_file_count "$abspath")

  log "  live process has it open (argv match): $(yes_no "$live_process")"
  log "  personal/scanned-document filename pattern: $(yes_no "$personal_match")"
  log "  inside a vendor cloud-sync mirror (CloudStorage): $(yes_no "$in_cloudstorage")"
  log "  git: root=${git_root:-none} tracked=$git_tracked ignored=$git_ignored has_remote=$has_remote"
  [ -n "$no_upstream_branches" ] && log "  branches with no upstream (unpushed, no GitHub copy): $no_upstream_branches"
  log "  days since last file modified inside: $days_dormant"
  log "  looks like a Python venv: $(yes_no "$is_venv")"
  log "  pure-cache directory name: $(yes_no "$pure_cache_name")"
  log "  file count: $file_count"
  log

  classify_recommend "$abspath" "$live_process" "$personal_match" "$in_cloudstorage" \
    "$no_upstream_branches" "$is_venv" "$git_tracked" "$has_remote" "$pure_cache_name" \
    "$days_dormant" "$file_count"
}

# classify_recommend <abspath> <live_process> <personal_match> <in_cloudstorage>
#   <no_upstream_branches> <is_venv> <git_tracked> <has_remote> <pure_cache_name>
#   <days_dormant> <file_count>
# Decision tree, in the same priority order as DATA_TIER_POLICY.md. Pure:
# reads only its arguments, prints the recommendation.
classify_recommend() {
  local abspath="$1" live_process="$2" personal_match="$3" in_cloudstorage="$4"
  local no_upstream_branches="$5" is_venv="$6" git_tracked="$7" has_remote="$8"
  local pure_cache_name="$9" days_dormant="${10}" file_count="${11}"

  if [ "$live_process" = 1 ]; then
    log "RECOMMENDATION: Tier 0 - never touch programmatically"
    log "  reason: a currently-running process has this path open (or another"
    log "  session's argv references it). Deleting/moving risks breaking live work."
    return 0
  fi
  if [ "$personal_match" = 1 ]; then
    log "RECOMMENDATION: Tier 0 - never touch programmatically"
    log "  reason: filename/path matches a personal or scanned-document pattern."
    log "  OCR/text extraction is never a substitute for the original file; if you"
    log "  want it backed up, copy it (Tier 2), never convert-and-delete it."
    return 0
  fi
  if [ "$in_cloudstorage" = 1 ]; then
    log "RECOMMENDATION: Tier 0 - never touch programmatically"
    log "  reason: lives inside a vendor's cloud-sync mirror (Dropbox/GDrive under"
    log "  Library/CloudStorage). Local-vs-cloud-only state here is a GUI-only"
    log "  setting (e.g. Dropbox Smart Sync) with no reliable CLI equivalent."
    return 0
  fi
  if [ -n "$no_upstream_branches" ]; then
    log "RECOMMENDATION: Tier 3 - archive to cloud (git bundle), then it's safe to"
    log "  leave the branches as-is or clean them up"
    log "  reason: these branches exist only on this disk. Run:"
    log "    git bundle create <name>.bundle --all --git-dir='$abspath/.git' (or cd + --all)"
    log "  then archive-evict the bundle. Do this before anything else on this path."
    return 0
  fi
  if [ "$is_venv" = 1 ] || { [ "$git_tracked" = 1 ] && [ "$days_dormant" != "unknown" ] && [ "$days_dormant" -lt "$TIER1_ACTIVE_DAYS" ] 2>/dev/null; }; then
    log "RECOMMENDATION: Tier 1 - permanent local, compress in place"
    log "  reason: $([ "$is_venv" = 1 ] && echo "Python venv - regenerable via requirements.txt/pyproject.toml, but until it's rebuilt something needs it as real files" || echo "git-tracked and recently active - likely read directly by current work")"
    log "  action: $0 compress-local '$abspath'"
    return 0
  fi
  if [ "$pure_cache_name" = 1 ]; then
    log "RECOMMENDATION: Tier 4 - delete immediately, no backup needed"
    log "  reason: name matches a known pure-cache pattern that regenerates from"
    log "  its package manager or build tool in seconds to minutes."
    return 0
  fi
  if [ "$git_tracked" = 1 ]; then
    if [ "$has_remote" = 1 ]; then
      log "RECOMMENDATION: Tier 2 - already cloud-backed via GitHub, keep local"
      log "  reason: git-tracked with a remote - it's already redundant. Do not"
      log "  also duplicate the working tree to Dropbox/GDrive; that's wasted"
      log "  space for zero extra safety. Deleting it locally only shows up as an"
      log "  uncommitted change, it doesn't free space until committed."
    else
      log "RECOMMENDATION: Tier 3 - archive to cloud (git bundle) - no remote configured"
      log "  reason: git-tracked but this repo has NO remote at all, so GitHub"
      log "  provides zero redundancy here. Bundle the whole repo, not just files."
    fi
    return 0
  fi
  if [ "$days_dormant" != "unknown" ] && [ "$days_dormant" -ge "$TIER3_DORMANT_DAYS" ] 2>/dev/null; then
    if [ "$file_count" -gt "$MANY_FILES_THRESHOLD" ] 2>/dev/null; then
      log "RECOMMENDATION: Tier 3 - archive to cloud, then evict (but check first"
      log "  whether this is a RECURRING regenerating cache, not a one-off)"
      log "  reason: dormant ($days_dormant days), untracked, and shaped like a"
      log "  many-small-files raw cache ($file_count files). If a pipeline"
      log "  regenerates this on its own schedule, add it to"
      log "  ~/.config/market-data/datasets.conf + cloud_backup.sh's"
      log "  STATIC_SUBDIRS instead of a one-off archive-evict, so re-archival"
      log "  stays automatic. Otherwise:"
      log "    $0 archive-evict '$abspath'"
    else
      log "RECOMMENDATION: Tier 3 - archive to cloud, then evict"
      log "  reason: dormant ($days_dormant days) and untracked - not read by"
      log "  anything found in a live-process check. Verify nothing depends on it"
      log "  before running:"
      log "    $0 archive-evict '$abspath'"
    fi
    return 0
  fi

  log "RECOMMENDATION: needs manual judgment"
  log "  reason: no rule matched cleanly (recently touched, untracked, not a"
  log "  known cache/venv shape). Read what actually references this path"
  log "  (grep the codebase, check what wrote it last) before deciding."
}

# ── all ──────────────────────────────────────────────────────────────────
cmd_all() {
  cmd_report
  echo
  cmd_clean_caches
  echo
  cmd_clean_packages
  echo
  cmd_trim_vms
}

# ── dispatch ─────────────────────────────────────────────────────────────
# A case chain rather than a lookup table: macOS bash 3.2 has no associative
# arrays, and every subcommand's argument shape differs anyway.
main() {
  case "${1:-}" in
    report)         cmd_report ;;
    clean-caches)   cmd_clean_caches ;;
    clean-packages) cmd_clean_packages ;;
    find-dormant)   cmd_find_dormant "${2:-$FIND_DORMANT_DEFAULT_DAYS}" ;;
    git-gc)         cmd_git_gc "${2:-.}" ;;
    trim-vms)       cmd_trim_vms ;;
    archive-evict)  cmd_archive_evict "${2:-}" "${3:-}" ;;
    list-archives)  cmd_list_archives ;;
    compress-local) shift; cmd_compress_local "$@" ;;
    classify)       cmd_classify "${2:-}" ;;
    all)            cmd_all ;;
    *)              usage; exit 1 ;;
  esac
}

main "$@"
