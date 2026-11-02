# cache_memory_cleaner

<!-- how-to-use-with-ai -->
> **New here?** See [How to use this repo with AI (Claude, Gemini, ChatGPT)](HOW_TO_USE_WITH_AI.md) — clone it, paste it into an AI tool, and ask in plain English.

A single bash script that recovers disk space on a personal macOS machine, distilled
from a real disk-space recovery session (99% full → healthy). It removes only what is
provably regenerable (browser and package-manager caches), reports — never removes —
dormant tools, and for everything else implements a five-tier data policy
(never-touch / compress / cloud-keep-local / archive-evict / delete-now) with a
read-only `classify` step and a "verify then evict" archiver. Output is plain text on
stdout; `archive-evict` additionally appends a TSV ledger of what went to the cloud.

> Status: active. Installed on the owner's Mac and called from scheduled jobs
> (`classify <path>`). This script deletes files — read the tier table and the hazards
> below before running anything other than `report`, `classify`, or `DRY_RUN=1`.

## What it does
- `clean-caches`: deletes browser render caches (Chrome, Brave, Firefox), Chrome's
  redownloadable on-device ML model caches and per-profile Service Worker/GPU caches,
  and Homebrew/pip/npm/uv/gem download caches — never IndexedDB, Extensions, or
  Local Storage.
- `clean-packages`: `brew autoremove`, `brew cleanup -s`, `npm cache clean --force`.
- `find-dormant [days]`: reports (only) brew leaves, ghost casks whose `.app` is gone,
  Application Support dirs with no file activity in N days (default 30), and
  never-started Podman machines.
- `git-gc [path]`: lists branches with no upstream, then `git gc --prune=now`.
- `trim-vms`: `podman system prune` plus `fstrim` inside the VM so the host-side sparse
  disk image actually shrinks.
- `archive-evict <path> [name]`: tar+zstd, upload to every rclone remote in
  `CLEANER_REMOTES`, byte-verify each, and only then delete the original and the local
  archive; logs each success to `~/.cache_memory_cleaner/archive_log.tsv`
  (`list-archives` prints it).
- `compress-local <path>...`: transparent HFS+/APFS compression via `afsctool`; files
  stay byte-identical to every reader, only on-disk size shrinks.
- `classify <path>`: read-only tier recommendation with the signals that drove it.

## Quick start
```bash
git clone https://github.com/herrrickshaw/cache_memory_cleaner.git
cd cache_memory_cleaner
chmod +x cache_memory_cleaner.sh
./cache_memory_cleaner.sh report                      # disk usage + top consumers, no changes
DRY_RUN=1 ./cache_memory_cleaner.sh clean-caches      # preview every rm before trusting it
./cache_memory_cleaner.sh classify ~/some/uncertain/directory
```

Full command list:

```
./cache_memory_cleaner.sh {report|clean-caches|clean-packages|find-dormant [days]|git-gc [path]|
                           archive-evict <path> [name]|list-archives|compress-local <path> [<path>...]|
                           classify <path>|trim-vms|all}
```

`all` = report + clean-caches + clean-packages + trim-vms. Any unknown subcommand
(including `--help`) prints the usage line and exits 1.

## How it works

One script, one function per subcommand (`cmd_*`), dispatched by a `case` in `main`
(macOS ships bash 3.2, so no associative arrays). Every mutating command goes through
`run`/`run_rm_rf`, which print the command instead of executing it when `DRY_RUN=1`;
there is no `eval`.

### The five-tier data policy behind `classify`

| Tier | Meaning | Typical case | Follow-up |
|---|---|---|---|
| 0 | Never touch programmatically | live app state, personal/scanned docs, vendor cloud-sync mirrors, another process's open files | leave alone |
| 1 | Permanent local, compress in place | Python venvs; git-tracked files modified in the last 7 days | `compress-local` |
| 2 | Cloud-backed, keep local | git-tracked with a remote (GitHub is already the backup) | nothing |
| 3 | Archive to cloud, then evict | untracked and untouched for ≥14 days; repos with no remote or with unpushed branches (bundle first) | `archive-evict` |
| 4 | Delete immediately, no backup | `__pycache__`, `node_modules`, `.npm`, Homebrew cache, etc. | `rm -rf` |
| ? | Needs manual judgment | recently touched, untracked, not a known shape | read what references it |

`classify` gathers signals (`sig_*` functions) and `classify_recommend` stops at the
first rule that matches, in this order: live process has the path in its argv →
personal-document filename pattern or `Documents/personal-archive/` → under
`~/Library/CloudStorage/` → repo with no-upstream branches → venv or recently-active
tracked file → pure-cache name → tracked (remote? Tier 2 : Tier 3) → dormant ≥14 days
(more than 500 files flags a recurring raw-cache shape) → manual. It never deletes,
moves, or compresses anything. The full policy with real examples lives in
[`DATA_TIER_POLICY.md`](https://github.com/herrrickshaw/repo-data-dedup/blob/main/DATA_TIER_POLICY.md)
in the companion `repo-data-dedup` repo.

### `archive-evict`: verify then evict

```bash
export CLEANER_REMOTES="dropbox:cache-archives googledrive:cache-archives"  # any rclone remote:path(s)
./cache_memory_cleaner.sh archive-evict ~/some/uncertain/directory
```

The path is tarred and zstd-compressed first (cloud APIs throttle per request, so a
directory of thousands of small files syncs raw in hours and as one archive in
minutes), uploaded to **every** remote, and each upload's byte size is compared with
the local archive. The original and the local archive are deleted **only if every
remote verifies**; otherwise both are kept. Each success is appended to
`$ARCHIVE_LOG` (date, original path, archive name, bytes, remotes).

### `compress-local`: data that must stay on disk

Measured on real data: a Python venv 209M → 92M (56% smaller) and still ran; a 123M
JSON knowledge-graph file → 6.2M (95% smaller), `json.load()` round-trip
byte-identical; 400 CSV/Markdown report files 60M → 16M (72.8% smaller). Best on
plain and structured text; skip JPEG/PNG, MP4, Office docs, `.git/objects`, Parquet
(`afsctool` no-ops on them but burns CPU). Idempotent and safe on live data.

## Repository layout
| Path | Purpose |
|---|---|
| `cache_memory_cleaner.sh` | the whole tool |
| `tests/smoke.sh`, `tests/expected/` | characterisation smoke test and recorded outputs (see Testing) |
| `.github/workflows/ci.yml` | `bash -n`, `shellcheck -S error`, smoke test on macOS |
| `.github/workflows/quality-gates.yml` | gitleaks secret scan |
| `HOW_TO_USE_WITH_AI.md` | plain-language guide for non-programmers |
| `compress_run*.log`, `graphify-out/` | logs from past runs and a knowledge-graph export; not used by the script |

## Configuration
All via environment variables; nothing is read from a config file and no secrets are
needed by the script itself (cloud credentials live in rclone's own config, never here).

| Variable | Default | Effect |
|---|---|---|
| `DRY_RUN` | `0` | `1` prints every mutating command instead of running it |
| `CLEANER_REMOTES` | unset → `dropbox:cache-archives` if a `dropbox:` rclone remote exists | space-separated rclone destinations for `archive-evict` |
| `ARCHIVE_STAGING` | `~/.cache_memory_cleaner/archives` | where the local `.tar.zst` is built |
| `ARCHIVE_LOG` | `~/.cache_memory_cleaner/archive_log.tsv` | ledger read by `list-archives` |

External tools, only when the subcommand needs them: `rclone` + `zstd`
(`archive-evict`), `afsctool` (`compress-local`, `brew install afsctool`), `brew`,
`npm`, `podman` (skipped if absent).

## Testing
```bash
tests/smoke.sh            # bash -n, usage, classify on fixtures, DRY_RUN=1 paths; diffs vs tests/expected
tests/smoke.sh --record   # re-record expectations after an intentional output change
```
The test builds its own sandbox, redirects `$HOME` into it for `clean-caches`, and
never runs a deleting subcommand for real. Expectations are macOS-specific (BSD
`stat`/`ps`), so CI uses `macos-latest`.

## Limitations and known issues
- 🔴 **Never point `CLEANER_REMOTES` at a path some other job mirrors with
  `rclone sync`.** A sync job deletes remote files absent from its local source —
  exactly what `archive-evict` just removed locally. This happened: four verified
  archives were wiped hours later by an unrelated nightly sync into the same folder.
  Use a destination nothing else ever syncs into.
- 🔴 `ditto --hfsCompression` silently no-ops on non-Apple content on recent macOS;
  the script uses `afsctool` instead.
- `classify`'s "live process" signal is an argv substring match on a `ps aux`
  snapshot; a process holding the path open without naming it in argv is not detected.
- `git gc` compacts reachable objects only; it never reclaims space from branches
  deleted without merging — that stays a human decision.
- A brew cask listed as installed can be a "ghost" whose `.app` was deleted by hand;
  `find-dormant` checks `/Applications` against `brew info --cask`.
- Pruning inside a VM does not shrink its host disk image until `fstrim` runs in the
  guest; `trim-vms` does both.
- PEP 668: packages in Homebrew Python's protected site-packages upgrade in place only
  with `--break-system-packages` (the same method they were installed with).
- macOS only (BSD `stat -f`, `df -g`, `ps aux` formats).

## Related repositories
- [repo-data-dedup](https://github.com/herrrickshaw/repo-data-dedup) — `DATA_TIER_POLICY.md`, the written policy `classify` implements.

## Licence
MIT — see [LICENSE](LICENSE).
