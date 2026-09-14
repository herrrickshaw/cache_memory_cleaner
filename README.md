# cache_memory_cleaner

A macOS cache/storage cleanup script, distilled from a real disk-space
recovery session (99% full → healthy). It only touches things that are
provably regenerable or provably unused — it will not delete a live
database, a running app's active state, or any data it can't verify is
safe to remove.

## Usage

```bash
git clone https://github.com/herrrickshaw/cache_memory_cleaner.git
cd cache_memory_cleaner
chmod +x cache_memory_cleaner.sh

./cache_memory_cleaner.sh report          # disk usage + top consumers, no changes
./cache_memory_cleaner.sh clean-caches    # clear browser + package-manager caches
./cache_memory_cleaner.sh clean-packages  # brew autoremove/cleanup, npm cache
./cache_memory_cleaner.sh find-dormant    # REPORT (not remove) unused tools/casks
./cache_memory_cleaner.sh git-gc [path]   # compact a git repo's objects
./cache_memory_cleaner.sh trim-vms        # prune + fstrim Podman VM disk images
./cache_memory_cleaner.sh archive-evict <path> [name]  # archive to the cloud, verify, THEN delete
./cache_memory_cleaner.sh list-archives   # show everything archive-evict has sent to the cloud
./cache_memory_cleaner.sh compress-local <path> [<path>...]  # transparent HFS/APFS compression
./cache_memory_cleaner.sh all             # report + clean-caches + clean-packages + trim-vms
```

Set `DRY_RUN=1` to preview every command without deleting anything:

```bash
DRY_RUN=1 ./cache_memory_cleaner.sh clean-caches
```

### `archive-evict` — for anything you're not 100% sure is disposable

Every other command in this tool only touches things that are provably
regenerable in seconds (a cache, a package download). Real cleanup sessions
keep running into a second category: data that's probably safe to remove but
would be a pain to lose or rebuild — an old VM/session-state folder, a
never-packed git repo's loose objects, a one-off dataset dump. For that,
delete-and-hope is the wrong call. `archive-evict` gives you a third option:

```bash
export CLEANER_REMOTES="dropbox:cache-archives googledrive:cache-archives"  # any rclone remote:path(s)
./cache_memory_cleaner.sh archive-evict ~/some/uncertain/directory
```

It tars+zstds the path, uploads it to **every** remote in `$CLEANER_REMOTES`,
byte-verifies each upload against the local archive, and deletes the original
(and the local archive) **only if every remote verifies**. If any upload or
verification fails, both copies are left in place — nothing is ever deleted on
a guess. Every successful run is appended to `~/.cache_memory_cleaner/archive_log.tsv`
(date, original path, archive name, size, remotes), so `list-archives` can
always answer "what did I move to the cloud, and where" months later —
requires [rclone](https://rclone.org) with your remotes already configured
(`rclone config`).

### `compress-local` — for data that has to stay on disk

Not everything belongs in the cloud — a live pipeline's working set, a repo's
own reports, an actively-read cache all need to stay local. For those,
`compress-local` applies macOS's native HFS+/APFS transparent compression
(`decmpfs`) instead:

```bash
brew install afsctool  # one-time
./cache_memory_cleaner.sh compress-local ~/some/path ~/another/path
```

This is **not** gzip. The file's name, extension, and content are completely
unchanged to every reader — a text editor, `cat`, `python -c "import json;
json.load(open(...))"`, a Python interpreter importing from a venv's
site-packages — all get the original bytes back automatically, with no
decompression step anywhere in your code or workflow. Only the on-disk
storage shrinks.

Measured on real data: a Python venv 209M → 92M (56% smaller), still executed
correctly afterward. A 123M JSON knowledge-graph file → 6.2M (95% smaller),
round-tripped through `json.load()` byte-identical. A directory of 400
CSV/Markdown report files: 60M → 16M (72.8% smaller).

Best candidates: plain and structured text — source code, CSV, JSON,
Markdown, logs, XML, venvs (mostly `.py`/`.txt`). Skip already-compressed
formats (JPEG/PNG, MP4, ZIP-based Office docs, `.git/objects`, Parquet) —
`afsctool` tries and safely no-ops on these, but running it there just burns
CPU. Safe to run repeatedly and safe on live/actively-read data: a reader
never observes a "compressing" state, only complete files before and after.

🔴 `ditto --hfsCompression` (built into macOS, no install needed) looks like
the obvious tool for this but is **not reliable** on recent macOS — it
silently no-ops on non-Apple content with no error. Use `afsctool`.

🔴 **Never point `CLEANER_REMOTES` at a path some other job mirrors with
`rclone sync`.** A sync job deletes remote files not present in its local
source to keep the two in lockstep — exactly what `archive-evict` just did to
its own upload the moment the local copy was removed. This is not
hypothetical: it happened in the session this feature was built from — four
archives, verified uploaded, wiped hours later by an unrelated nightly sync
job that happened to target the same remote folder for a different dataset.
Use a destination nothing else ever syncs into.

## What it cleans

- Browser render caches (Chrome, Brave, Firefox) — apps rebuild these on demand
- Chrome's redownloadable on-device ML model caches (`OptGuideOnDeviceModel`,
  `screen_ai`, etc.) and per-profile Service Worker/GPU caches — **not**
  `IndexedDB`, `Extensions`, or `Local Storage`, which can hold real data
- Homebrew, pip, npm, uv, and gem download caches
- Orphaned Homebrew dependencies (`brew autoremove`) and old formula versions
  (`brew cleanup`)

## What it only *reports*, never removes automatically

- `find-dormant`: Homebrew leaves, ghost casks (registered but the `.app` was
  deleted by hand), Application Support directories with zero recent file
  activity, and never-started Podman VMs. All of these need a human decision
  — the script won't guess whether you still need a tool.
- `git-gc`: branches with no upstream (their commits exist nowhere but your
  disk) get listed as a warning before the `gc` runs. `git gc` itself is safe
  regardless of push status — it compacts *reachable* objects, it never
  deletes branch history — but it's still worth knowing which branches have
  no off-machine backup.

## Lessons baked into this tool

- **Verify then evict.** Never delete a local copy because you *think* it's
  backed up — check the remote copy's byte size matches first.
- **Archive many-small-files directories before uploading.** Cloud APIs
  (Dropbox, Google Drive) throttle per-request, not per-byte. A directory
  with tens of thousands of small files can take hours to sync raw; the same
  data tarred into one archive uploads in minutes.
- **A cask being "installed" doesn't mean the app exists.** Check
  `/Applications` against `brew info --cask <name>`'s real app name — apps
  deleted by hand outside of Homebrew leave a stale registry entry.
- **A VM/container runtime that shows "never started" is pure waste.**
  `podman machine list` (or the equivalent for your container tool) will
  tell you if a multi-GB disk allocation was set up and never touched.
- **PEP 668 needs `--break-system-packages` for in-place upgrades** of
  packages already living in Homebrew's protected Python site-packages —
  the same method they were originally installed with, not a workaround.
- **Pruning inside a VM doesn't shrink its host-side disk image.** A guest
  OS marks freed blocks internally, but the host's sparse file only shrinks
  once something issues a real discard. `podman system prune` freeing 1.76GB
  *inside* a VM left its 10GB host footprint untouched; `fstrim -av` over
  `podman machine ssh` afterward dropped it to 2GB, machine still fully usable.

## License

MIT
