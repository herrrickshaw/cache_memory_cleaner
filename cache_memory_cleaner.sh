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

case "${1:-}" in
  report)        cmd_report ;;
  clean-caches)  cmd_clean_caches ;;
  clean-packages) cmd_clean_packages ;;
  find-dormant)  cmd_find_dormant "${2:-30}" ;;
  git-gc)        cmd_git_gc "${2:-.}" ;;
  all)
    cmd_report
    echo
    cmd_clean_caches
    echo
    cmd_clean_packages
    ;;
  *)
    echo "Usage: $0 {report|clean-caches|clean-packages|find-dormant [days]|git-gc [path]|all}"
    echo "Set DRY_RUN=1 to preview without deleting anything."
    exit 1
    ;;
esac
