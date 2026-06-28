# Zip-Dedupe

`UnzipDupe.sh` — a parallel, safe, dedup-aware bulk archive extractor.

Point it at a directory full of archives. It extracts each one, skips anything
whose destination already exists (the "dedupe"), and deletes each source file
once it has been successfully extracted. It runs many extractions in parallel
and uses the fastest **safe** extractor and decompressor available on the host.

## Features

- **Many formats, auto-detected handlers**
  - Archives: `.zip` `.7z` `.rar` `.tar` `.tar.gz`/`.tgz` `.tar.bz2`/`.tbz2`
    `.tar.xz`/`.txz` `.tar.zst`/`.tzst`
  - Single-file compressors: `.gz` `.bz2` `.xz` `.zst` `.lz4` `.lzma` `.Z`
    (decompressed in place; auto-extracted if the payload is actually a tar)
- **Dedup by destination** — re-running over a partly-processed directory is
  cheap and idempotent; existing destinations are skipped.
- **Safe by design** — extracts into a private staging dir on the target
  filesystem, claims the destination atomically (`mkdir`) before doing work,
  collapses an archive that already wraps one top folder (no double-nesting),
  rejects symlinks that escape the archive root, and rolls back cleanly on
  failure (the source archive is kept).
- **Fast** — parallel across archives (`-j`, default `nproc`) and uses parallel
  decompressors when present (`pigz`, `lbzip2`/`pbzip2`, `zstd`, `xz -T0`,
  `lz4`).

## Usage

```bash
./UnzipDupe.sh [options] [TARGET_DIR]      # TARGET_DIR defaults to the current dir
```

Examples:

```bash
./UnzipDupe.sh                              # process the current directory
./UnzipDupe.sh ~/Downloads                  # process a specific directory
./UnzipDupe.sh -j8 /mnt/data                # 8 parallel workers
./UnzipDupe.sh --dry-run ~/Downloads        # preview; change nothing
./UnzipDupe.sh --keep ~/Downloads           # extract but keep the source archives
```

### Options

| Option | Description |
| --- | --- |
| `-j, --jobs N` | Parallel workers (default: `nproc`). |
| `-k, --keep` | Keep source archives after extraction. |
| `-n, --dry-run` | Show what would happen; change nothing. |
| `--prune-duplicates` | Delete a source whose destination already exists. |
| `-q, --quiet` | Only warnings, errors, and the final summary. |
| `-v, --verbose` | Extra per-archive diagnostics. |
| `--color=WHEN` | `auto` (default), `always`, or `never`. |
| `-h, --help` | Show help. |

## Requirements

- `bash` ≥ 4.3 (for `wait -n`) and `tar` **or** `bsdtar`.
- Optional accelerators / format handlers, auto-detected: `bsdtar` (libarchive),
  `7z`/`7zz`/`7za`, `unzip`, `unrar`, `pigz`, `lbzip2`/`pbzip2`, `zstd`, `xz`,
  `lz4`.

Install the accelerators for best speed and widest format coverage, e.g. on
Debian/Ubuntu:

```bash
sudo apt-get install pigz lbzip2 zstd lz4 xz-utils libarchive-tools p7zip-full unzip
```

## Notes & caveats

- Non-recursive: only the top level of `TARGET_DIR` is scanned.
- Sources are **deleted on success** (use `--keep` to retain them).
- GNU `tar` and `bsdtar` are safe-by-default against path traversal and are
  preferred; the native `unzip`/`7z`/`unrar` fallbacks rely on the host tool
  being a modern, traversal-safe build.
- Primarily targets Linux (GNU coreutils); BSD/macOS shims are included for
  `stat` and `nproc`.

## Testing

```bash
shellcheck UnzipDupe.sh
bash tests/run.sh
```

## License

See [LICENSE](LICENSE).
