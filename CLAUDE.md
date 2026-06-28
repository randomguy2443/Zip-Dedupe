# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script (`UnzipDupe.sh`) that bulk-extracts archives sitting in one
directory, then deletes each source after a successful extraction. "Dedupe"
refers to **collision avoidance at the destination level** — an archive is
skipped when its destination already exists — not content-level deduplication of
files inside archives.

It handles two shapes of input:
- **Archives** (`.zip .7z .rar .tar .tar.gz/.tgz .tar.bz2/.tbz2 .tar.xz/.txz
  .tar.zst/.tzst`) → extracted into a folder.
- **Bare single-file compressors** (`.gz .bz2 .xz .zst .lz4 .lzma .Z`) →
  decompressed in place to a single file (e.g. `foo.pdf.gz` → `foo.pdf`), unless
  the decompressed payload is itself a tar, in which case it is auto-extracted
  into a folder.

There is no build system. There is a small functional test suite under `tests/`
(see Testing). The only dependencies are the external CLI tools the script
shells out to, all auto-detected at runtime.

## Running it

```bash
./UnzipDupe.sh [options] [TARGET_DIR]    # TARGET_DIR defaults to the current dir
./UnzipDupe.sh --help                    # full option list
```

Key options: `-j/--jobs N` (parallel workers, default `nproc`), `-k/--keep`
(don't delete sources), `-n/--dry-run`, `--prune-duplicates` (delete a source
whose destination already exists), `-q/--quiet`, `-v/--verbose`, `--color`.

Tools are auto-detected; the fastest **safe** option is preferred (`bsdtar`/GNU
`tar`, including `bsdtar` for zip/7z) and the fastest available **parallel
decompressor** per format is used (`pigz`, `lbzip2`/`pbzip2`, `zstd`, `xz -T0`,
`lz4`). `set -euo pipefail` is on; only `tar` *or* `bsdtar` is strictly
required.

## Architecture / control flow

`main` finds inputs via a NUL-terminated, `-maxdepth 1` `find`, then dispatches
`process_archive` as background jobs throttled by a `wait -n` pool against
`JOBS` (blocks *before* each spawn, so the cap is strict, no busy-wait). Each
worker writes exactly one result line into a per-run results dir; `main` tallies
them after `wait` and prints a summary (extracted / skipped / reclaimed bytes /
elapsed).

`process_archive` is a dispatcher that routes by extension to one of two paths;
both extract into a **private, run-scoped staging dir on the target filesystem**
(`.unzipdupe.stage.$RUNID.XXXXXX`) so final placement is an atomic rename,
partial failures never pollute the target, and cross-archive symlink attacks
cannot chain through a shared extraction root.

1. **`handle_archive`** (multi-file archives):
   - `list_archive` lists contents (dispatched by extension), normalizing
     `\`→`/` and stripping `\r`; macOS cruft is filtered for the name decision.
   - `predict_dest_name` normalizes leading `./` and `/`, then picks the inner
     root folder for a single-root archive or the archive base name otherwise.
     A `.`/`..`/empty result is rejected (defends against a crafted index).
   - **Atomic dedup claim**: `mkdir "$dest"` *before* extracting. If it fails,
     the destination already exists → skip (or, with `--prune-duplicates`,
     delete the source). This avoids re-extracting on re-runs and is race-free.
   - `extract_to` extracts into the staging dir; `finalize_stage_into_dest`
     prunes cruft, runs the symlink-escape guard, collapses a sole real
     top-level directory, and moves the contents into the claimed destination.
2. **`handle_compressed`** (bare single-file compressors):
   - `decompress_stream` streams the file into the staging dir (parallel
     decompressor when available). `is_tar` then checks the result: if it is a
     tar, it is extracted via the same folder-placement path; otherwise the
     single decompressed file is placed directly with a race-safe hardlink
     claim and **file-level** dedup.

**Destructive outcomes**: on success the source is `rm -f`'d (unless `--keep`);
on any failure the claimed destination and staging dir are rolled back
(`finalize_stage_into_dest` removes both). A `trap` cleans this run's staging
dirs and results dir on exit/interrupt and kills only this script's own workers.

## When modifying

Adding or changing a supported **archive** format means touching, in sync:
`detect_tools`, the `list_archive` case, the `extract_to` case, the dispatch
`case` in `process_archive`, the extension lists in `strip_archive_ext`, and the
`find` filter in `main`. For a **single-file compressor**, touch `detect_tools`,
`decompress_stream`, `strip_compressor_ext`, the dispatch `case`, and the `find`
filter. The listing/extraction logic must agree on the top-level layout, or the
single-root/flat decision (and thus the rollback path) will be wrong.

## Testing

```bash
shellcheck UnzipDupe.sh        # static analysis (clean)
bash tests/run.sh              # functional suite (builds sample archives in a
                               # temp dir, runs the script, asserts placement,
                               # dedup, deletion, rollback, and each format)
```

`tests/run.sh` is self-contained and guards each format by tool availability, so
it runs anywhere and only exercises formats whose tools are installed.
