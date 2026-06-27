# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script (`UnzipDupe.sh`) that bulk-extracts archives sitting in one
directory, then deletes each archive after a successful extraction. "Dedupe"
refers to **collision avoidance at the folder level** — it skips any archive
whose destination folder already exists — not content-level deduplication of
files inside archives.

There is no build system, no test suite, and no dependencies to install beyond
the external CLI tools the script shells out to.

## Running it

```bash
./UnzipDupe.sh        # operates on the hardcoded TARGET_DIR
```

Before running, edit the two configuration constants at the top of the script:
- `TARGET_DIR` — directory scanned for archives (currently hardcoded to an
  absolute path). The script `cd`s here and only scans `-maxdepth 1`.
- `MAX_JOBS` — number of archives extracted in parallel.

Required external tools (the script assumes they are on `PATH`): `unzip`, `tar`,
`7z` (p7zip), and optionally `unrar`. `.rar` and unknown extensions fall back to
`7z`. `set -euo pipefail` is on, so missing tools or unset vars fail loudly.

## Architecture / control flow

`main` finds archives via a null-terminated `find`, then dispatches
`process_archive` as background jobs, throttling concurrency with a
`jobs -r` / `wait -n` barrier loop against `MAX_JOBS`.

The central design decision lives in `process_archive`: **single-root vs.
flat-archive handling**, which determines the extraction destination.

1. `list_archive` lists archive contents without extracting (dispatched by
   extension: `unzip -Z -1`, `tar -tf`, or `7z l -slt`), normalizing `\` → `/`
   and stripping `\r`. macOS cruft (`__MACOSX`, `.DS_Store`) is filtered out.
2. If the archive has exactly **one top-level entry and it's a directory**
   (`is_single_root`), it is extracted directly into `TARGET_DIR` (the archive
   already provides its own wrapper folder). Otherwise the archive is treated as
   "flat" and extracted into a new folder named after the archive's base name
   (`get_base_name` strips compound extensions like `.tar.gz`).
3. **Dedupe check**: if the computed destination (`target_path`) already exists,
   the archive is skipped entirely — this is the deduplication behavior.
4. Extraction is dispatched by extension again (a second `case`).
5. **Destructive outcomes**: on success the source archive is `rm -f`'d; on
   failure the partially-created destination is rolled back (`rm -rf`). Keep
   both branches consistent if you add formats or change destination logic — the
   rollback must target whatever directory extraction created.

A `trap ... INT TERM` runs `kill 0` to take down all worker subprocesses on
interrupt.

## When modifying

Adding or changing a supported format means touching **three** places in sync:
the `list_archive` case, the `process_archive` extraction case, and the
extension lists in both `get_base_name`'s `sed` and `main`'s `find`. The listing
and extraction logic must agree on which top-level layout an archive has, or the
single-root/flat decision (and thus rollback path) will be wrong.
