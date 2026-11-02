#!/usr/bin/env bash
# Characterisation smoke test for cache_memory_cleaner.sh.
#
# Runs only read-only / dry-run paths (`bash -n`, usage, `classify`, and
# DRY_RUN=1 subcommands) against a throw-away sandbox it creates itself, then
# diffs the normalised output against tests/expected/*.txt.
#
#   tests/smoke.sh            # compare against the recorded expectations
#   tests/smoke.sh --record   # (re)write tests/expected from the current script
#
# Nothing outside the sandbox is ever read as a *target*; $HOME is pointed at
# the sandbox for the clean-caches case so no real cache directory is touched.
# Expectations are macOS-specific (BSD stat/ps), so CI runs on macos-latest.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCRIPT="$REPO/cache_memory_cleaner.sh"
EXPECTED="$HERE/expected"
MODE="${1:-compare}"

SANDBOX="${SMOKE_SANDBOX:-${TMPDIR:-/tmp}/cmc-smoke-$$}"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX" "$EXPECTED"
SANDBOX=$(cd "$SANDBOX" && pwd -P)   # canonical: the script resolves paths the same way
trap 'rm -rf "$SANDBOX"' EXIT

fail=0
OLD_STAMP=202001010000   # well over the 14-day dormancy threshold

# ── fixtures ──────────────────────────────────────────────────────────────
make_fixtures() {
  local s="$SANDBOX"
  mkdir -p "$s/recent" && echo x > "$s/recent/a.txt"

  mkdir -p "$s/__pycache__" && echo x > "$s/__pycache__/m.pyc"
  mkdir -p "$s/node_modules/pkg" && echo x > "$s/node_modules/pkg/index.js"

  mkdir -p "$s/venv/bin" && echo home=/usr/bin > "$s/venv/pyvenv.cfg" && : > "$s/venv/bin/activate"

  mkdir -p "$s/docs" && : > "$s/docs/passport_scan.pdf"
  mkdir -p "$s/Documents/personal-archive" && echo x > "$s/Documents/personal-archive/notes.txt"

  mkdir -p "$s/dormant_small" && echo x > "$s/dormant_small/f.txt"
  touch -t "$OLD_STAMP" "$s/dormant_small/f.txt"

  mkdir -p "$s/dormant_many"
  local i=1
  while [ "$i" -le 501 ]; do : > "$s/dormant_many/f$i"; i=$((i + 1)); done
  touch -t "$OLD_STAMP" "$s"/dormant_many/f*

  : > "$s/lonefile.txt"
  touch -t "$OLD_STAMP" "$s/lonefile.txt"

  # git repo, tracked file, no remote
  git -c init.defaultBranch=main init -q "$s/repo_noremote"
  echo x > "$s/repo_noremote/tracked.txt"
  git -C "$s/repo_noremote" add tracked.txt
  git -C "$s/repo_noremote" -c user.name=t -c user.email=t@t commit -qm init

  # git repo with a remote; tracked old file; untracked old file
  git -c init.defaultBranch=main init -q "$s/repo_remote"
  echo x > "$s/repo_remote/tracked.txt"
  echo y > "$s/repo_remote/untracked.txt"
  git -C "$s/repo_remote" add tracked.txt
  git -C "$s/repo_remote" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$s/repo_remote" remote add origin "$s/nowhere.git"
  touch -t "$OLD_STAMP" "$s/repo_remote/tracked.txt" "$s/repo_remote/untracked.txt"

  # fake caches under a sandbox $HOME for the clean-caches dry run
  mkdir -p "$s/home/Library/Caches/Google" "$s/home/Library/Caches/pip" "$s/home/.npm"
  mkdir -p "$s/home/Library/Application Support/Google/Chrome/Default/GPUCache"
  mkdir -p "$s/home/Library/Application Support/Google/Chrome/screen_ai"

  printf '2026-01-01T00:00:00Z\t/x/y\ty-20260101.tar.zst\t12345\tdropbox:cache-archives\n' > "$s/archive_log.tsv"
}

# ── runner ────────────────────────────────────────────────────────────────
# normalise: replace the script path, sandbox path, and day counts / sizes
# that legitimately vary between runs.
normalise() {
  sed -e "s#$SCRIPT#@SCRIPT@#g" -e "s#$SANDBOX#@SANDBOX@#g" \
      -e 's/\(days since last file modified inside: \)[0-9][0-9]*/\1@N@/' \
      -e 's/dormant ([0-9][0-9]* days)/dormant (@N@ days)/' \
      -e 's/\(Free space: \)[0-9]*GB -> [0-9]*GB/\1@N@GB -> @N@GB/' \
      -e 's/-[0-9]\{8\}\.tar\.zst/-@DATE@.tar.zst/g' \
      -e 's/^\.git: .*/.git: @SIZE@ -> @SIZE@/' \
      -e 's/^\(=== Running git gc (.git currently: \).*/\1@SIZE@) ===/'
}

# case <name> <env...> -- <args...>
run_case() {
  local name="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local out
  out=$( (cd "$SANDBOX" && env "${envs[@]}" "$SCRIPT" "$@" 2>&1; echo "exit=$?") | normalise )
  if [ "$MODE" = "--record" ]; then
    printf '%s\n' "$out" > "$EXPECTED/$name.txt"
    echo "recorded $name"
  elif diff -u "$EXPECTED/$name.txt" <(printf '%s\n' "$out"); then
    echo "ok   $name"
  else
    echo "FAIL $name"; fail=1
  fi
}

# ── cases ─────────────────────────────────────────────────────────────────
if bash -n "$SCRIPT"; then echo "ok   bash -n"; else echo "FAIL bash -n"; fail=1; fi
make_fixtures
S="$SANDBOX"
run_case usage_noargs      DRY_RUN=1 --
run_case usage_help        DRY_RUN=1 -- --help
run_case classify_noarg    DRY_RUN=1 -- classify
run_case classify_missing  DRY_RUN=1 -- classify "$S/does-not-exist"
run_case classify_recent   DRY_RUN=1 -- classify "$S/recent"
run_case classify_pycache  DRY_RUN=1 -- classify "$S/__pycache__"
run_case classify_nodemods DRY_RUN=1 -- classify "$S/node_modules/"
run_case classify_venv     DRY_RUN=1 -- classify "$S/venv"
run_case classify_personal DRY_RUN=1 -- classify "$S/docs/passport_scan.pdf"
run_case classify_parchive DRY_RUN=1 -- classify "$S/Documents/personal-archive/notes.txt"
run_case classify_dormant  DRY_RUN=1 -- classify "$S/dormant_small"
run_case classify_manyfile DRY_RUN=1 -- classify "$S/dormant_many"
run_case classify_lonefile DRY_RUN=1 -- classify "$S/lonefile.txt"
run_case classify_noremote DRY_RUN=1 -- classify "$S/repo_noremote/tracked.txt"
run_case classify_norem_up DRY_RUN=1 -- classify "$S/repo_noremote"
run_case classify_tracked  DRY_RUN=1 -- classify "$S/repo_remote/tracked.txt"
run_case classify_untrackd DRY_RUN=1 -- classify "$S/repo_remote/untracked.txt"
run_case cleancaches_dry   DRY_RUN=1 "HOME=$S/home" -- clean-caches
run_case gitgc_dry         DRY_RUN=1 -- git-gc "$S/repo_remote"
run_case gitgc_notrepo     DRY_RUN=1 -- git-gc "$S/recent"
run_case listarchives_none DRY_RUN=1 "ARCHIVE_LOG=$S/none.tsv" -- list-archives
run_case listarchives_one  DRY_RUN=1 "ARCHIVE_LOG=$S/archive_log.tsv" -- list-archives
run_case archive_noarg     DRY_RUN=1 -- archive-evict
run_case compress_noarg    DRY_RUN=1 -- compress-local
if command -v rclone >/dev/null 2>&1; then
  run_case archive_dry DRY_RUN=1 "ARCHIVE_STAGING=$S/staging" "ARCHIVE_LOG=$S/al.tsv" \
    CLEANER_REMOTES=fake:cache-archives -- archive-evict "$S/dormant_small"
fi
if command -v afsctool >/dev/null 2>&1; then
  run_case compress_dry DRY_RUN=1 -- compress-local "$S/recent" "$S/missing"
fi

[ "$fail" = 0 ] && echo "ALL OK" || { echo "SMOKE FAILED"; exit 1; }
