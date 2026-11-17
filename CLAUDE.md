# CLAUDE.md

Guidance for Claude Code sessions working in this repository.

## This repository

- One script, `cache_memory_cleaner.sh` (bash 3.2-compatible: no associative arrays, no `mapfile`;
  `set -uo pipefail`, deliberately no `-e`). One `cmd_*` function per subcommand, `sig_*` signal
  functions + `classify_recommend` for the tier decision, `run`/`run_rm_rf`/`run_shown` for every
  mutating command (honour `DRY_RUN=1`; no `eval`).
- It deletes files. Never run `clean-caches`, `clean-packages`, `archive-evict`, `trim-vms` or `all`
  against real paths while developing; test with `classify`, `--help`, and `DRY_RUN=1` in a temp dir.
- Subcommand names, flags, exit codes, tier names and output text are a contract with scheduled jobs
  on the owner's Mac. Run `tests/smoke.sh` after any change; re-record with `tests/smoke.sh --record`
  only for an intentional output change, and say so in the commit.
- 🔴 `CLEANER_REMOTES` must never point at a folder another job `rclone sync`s (see README,
  "Limitations and known issues").

<!-- source-fetch-toolkit:v1 (managed by ~/bin/add_source_fetch_section.py — edit there, not here) -->
## Source fetching for data collection & literature surveys

When a task needs a primary document (statute, regulator data, government release, paper, filing),
fetch the document itself — never cite a search snippet as if it had been read.

- **On the owner's Mac:** `fetch_source.py "<url | doi:… | celex:… | arxiv:…>" --out ./sources`
  (in `~/bin`; full guide `~/bin/SOURCE_FETCH_TOOLKIT.md`). Scheduled/unattended runs use only
  `bash /Users/umashankar/bin/fetch_source.sh "<target>"` (allowlisted) and then Read the `.txt` it reports.
- **Elsewhere (cloud sessions, CI):** follow the same ladder by hand — direct GET with a browser User-Agent →
  headless browser only if the page needs JavaScript → official alternates (DOI → OpenAlex
  `api.openalex.org/works/doi:<doi>` locations → repository copy; EUR-Lex → EU Publications Office
  `publications.europa.eu/resource/celex/<CELEX>`; arXiv pdf/abs) → Wayback Machine `id_` snapshot.
- **Hard rule:** a CAPTCHA, robot check, Cloudflare/Akamai/WAF challenge or login wall means stop on that
  host. Do not bypass it (no TLS impersonation, stealth browsers, identity rotation or challenge solving);
  look for the same document via another route, or report it as unavailable.
- **Record** for every figure: URL read, title/date, page/table, fetch route; mark abstract-only or
  snippet-only sources. Fetch politely (~1 request/second per host, no bulk crawling).
<!-- /source-fetch-toolkit -->
