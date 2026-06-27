#!/usr/bin/env bash
#
# ==============================================================================
#  UnzipDupe.sh  --  parallel, safe, dedup-aware bulk archive extractor
# ==============================================================================
#
#  Extracts every archive found in a target directory, then deletes each source
#  archive once it has been successfully extracted. "Dedupe" means destination
#  collision avoidance: an archive is skipped when its destination folder
#  already exists, so re-running over a partially-processed directory is cheap
#  and idempotent.
#
#  Design highlights
#  -----------------
#   * Per-archive private staging dir on the SAME filesystem as the target, so
#     final placement is an atomic rename, partial failures never pollute the
#     target, and cross-archive symlink attacks (cf. CVE-2025-45582) cannot
#     chain through a shared extraction root.
#   * Race-free dedup: the destination is claimed with an atomic `mkdir` BEFORE
#     any files are written to disk, so two workers never fight over a
#     destination and a duplicate is retired without a full extract-and-place.
#     (Deciding the destination name still enumerates the archive index first;
#     for zip/7z/rar that reads the cheap central directory, but for a
#     compressed .tar.* it is a streaming decompression pass -- there is no
#     random access into a compressed tar.)
#   * Single-root collapse from the filesystem (authoritative), so an archive
#     that already wraps its own top-level folder is never double-nested. The
#     predicted name is validated and sanitized (leading ./ and / stripped,
#     '.'/'..' rejected), so a crafted index cannot redirect the destination.
#   * Runtime tool detection picks the fastest SAFE extractor available and the
#     fastest parallel decompressor per format (lbzip2 for bzip2 is the big
#     win; xz -T0 only helps multi-block streams; gzip/zstd decompression are
#     effectively single-threaded -- see NOTES). The dominant speedup for a
#     directory of many archives is outer parallelism (-j), not per-file
#     threading; this script maximizes both.
#   * Defense in depth: a symlink-escape scan rejects any extracted tree that
#     contains a symlink resolving outside its staging dir.
#   * Safety scope: GNU tar and bsdtar are safe-by-default against ../ and
#     absolute paths; this script prefers them (incl. bsdtar for zip and 7z).
#     The native unzip/7z/unrar fallbacks rely on the host tool being a modern,
#     traversal-safe build, and the symlink scan cannot detect a *regular* file
#     written outside the stage by a vulnerable extractor. Targets Linux (GNU
#     coreutils); BSD/macOS shims are noted inline (stat, nproc).
#
#  Usage:  ./UnzipDupe.sh [options] [TARGET_DIR]
#  Run    ./UnzipDupe.sh --help    for the full option list.
#
#  Requires bash >= 4.3 (for `wait -n`) plus `tar`; optional accelerators and
#  format handlers are auto-detected: bsdtar(libarchive), 7z/7zz/7za, unzip,
#  unrar, pigz, lbzip2/pbzip2, zstd, xz.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Defaults (override via CLI flags / positional TARGET_DIR / environment)
# ------------------------------------------------------------------------------
DEFAULT_TARGET_DIR="/home/ares/mnt/NTFS-Drive2/sm2/"

TARGET_DIR=""
JOBS=""
KEEP=0                 # --keep            : never delete source archives
DRY_RUN=0              # --dry-run / -n    : show planned actions, change nothing
PRUNE_DUPLICATES=0     # --prune-duplicates: delete a source whose dest exists
QUIET=0                # --quiet / -q      : only warnings, errors and summary
VERBOSE=0              # --verbose / -v    : extra per-archive detail
COLOR_MODE="auto"      # --color=auto|always|never

# ------------------------------------------------------------------------------
# Colors (resolved after option parsing, tty-aware)
# ------------------------------------------------------------------------------
CLR_RESET="" CLR_INFO="" CLR_OK="" CLR_WARN="" CLR_ERR="" CLR_DIM=""
setup_colors() {
    local on=0
    case "$COLOR_MODE" in
        always) on=1 ;;
        never)  on=0 ;;
        *)      [[ -t 2 ]] && on=1 ;;
    esac
    if (( on )); then
        CLR_RESET=$'\e[0m'; CLR_INFO=$'\e[34m'; CLR_OK=$'\e[32m'
        CLR_WARN=$'\e[33m'; CLR_ERR=$'\e[31m';  CLR_DIM=$'\e[2m'
    fi
}

# ------------------------------------------------------------------------------
# Logging -- single printf per line is atomic for lines < PIPE_BUF (4 KiB),
# which keeps parallel worker output from interleaving mid-line. All logs go to
# stderr so stdout stays clean.
# ------------------------------------------------------------------------------
log_info() { (( QUIET )) || printf '%s[*]%s %s\n' "$CLR_INFO" "$CLR_RESET" "$*" >&2; }
log_ok()   { (( QUIET )) || printf '%s[+]%s %s\n' "$CLR_OK"   "$CLR_RESET" "$*" >&2; }
log_warn() {              printf '%s[!]%s %s\n' "$CLR_WARN" "$CLR_RESET" "$*" >&2; }
log_err()  {              printf '%s[x]%s %s\n' "$CLR_ERR"  "$CLR_RESET" "$*" >&2; }
log_dbg()  { (( VERBOSE )) || return 0; printf '%s[.] %s%s\n' "$CLR_DIM" "$*" "$CLR_RESET" >&2; }

die() { log_err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Tool detection
# ------------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

HAVE_BSDTAR=0 HAVE_7Z=0 HAVE_UNZIP=0 HAVE_UNRAR=0
HAVE_PIGZ=0 HAVE_LBZIP2=0 HAVE_PBZIP2=0 HAVE_ZSTD=0 HAVE_XZ=0
SEVENZIP=""
GZ_PROG="" BZ_PROG="" ZSTD_PROG=""   # external decompressors for GNU tar (-I)

detect_tools() {
    have bsdtar && HAVE_BSDTAR=1
    have unzip  && HAVE_UNZIP=1
    have unrar  && HAVE_UNRAR=1
    local c
    for c in 7zz 7z 7za; do
        if have "$c"; then SEVENZIP="$c"; HAVE_7Z=1; break; fi
    done
    have pigz   && HAVE_PIGZ=1
    have lbzip2 && HAVE_LBZIP2=1
    have pbzip2 && HAVE_PBZIP2=1
    have zstd   && HAVE_ZSTD=1
    have xz     && HAVE_XZ=1

    # Fastest available parallel decompressor per format. GNU tar invokes the
    # named program with `-d` appended, so only a bare program name is passed.
    (( HAVE_PIGZ ))                  && GZ_PROG="pigz"
    if   (( HAVE_LBZIP2 )); then BZ_PROG="lbzip2"
    elif (( HAVE_PBZIP2 )); then BZ_PROG="pbzip2"; fi
    (( HAVE_ZSTD ))                  && ZSTD_PROG="zstd"

    have tar || (( HAVE_BSDTAR )) || die "neither 'tar' nor 'bsdtar' is available"
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
# Strip a (possibly compound) archive extension, case-insensitively. Pure bash
# (no GNU `sed ...$/I`), longest compound suffix first, original case preserved.
strip_archive_ext() {
    local f=$1 low=${1,,} ext
    for ext in .tar.gz .tar.xz .tar.bz2 .tar.zst .tgz .txz .tbz2 .tzst .tar .zip .7z .rar; do
        if [[ $low == *"$ext" ]]; then printf '%s' "${f:0:${#f}-${#ext}}"; return; fi
    done
    printf '%s' "$f"
}

# List archive contents (one path per line) without extracting. Output is
# normalized: CRs stripped, backslashes -> slashes. Used only to predict the
# destination name and to detect corruption; final placement is decided from
# the extracted filesystem, so rare listing quirks cannot corrupt the result.
sevenzip_list() { "$SEVENZIP" l -slt "$1" 2>/dev/null | awk '/^Path = /{c++; if (c>1) print substr($0,8)}'; }

list_archive() {
    local f=$1 low=${1,,}
    {
        case "$low" in
            *.zip)
                if   (( HAVE_UNZIP ));  then unzip -Z1 "$f"
                elif (( HAVE_BSDTAR )); then bsdtar -tf "$f"
                elif (( HAVE_7Z ));     then sevenzip_list "$f"; fi ;;
            *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tar.zst|*.tzst)
                if (( HAVE_BSDTAR )); then bsdtar -tf "$f"; else tar -tf "$f"; fi ;;
            *.7z)
                if   (( HAVE_7Z ));     then sevenzip_list "$f"
                elif (( HAVE_BSDTAR )); then bsdtar -tf "$f"; fi ;;
            *.rar)
                if   (( HAVE_UNRAR ));  then unrar lb "$f"
                elif (( HAVE_7Z ));     then sevenzip_list "$f"
                elif (( HAVE_BSDTAR )); then bsdtar -tf "$f"; fi ;;
            *)
                if   (( HAVE_BSDTAR )); then bsdtar -tf "$f"
                elif (( HAVE_7Z ));     then sevenzip_list "$f"; fi ;;
        esac
    } 2>/dev/null | tr -d '\r' | tr '\134' '/'
}

# Extract $archive into directory $dest. Returns 0 on success, 1 on extraction
# error, 2 when no capable tool is installed. stdout is discarded; stderr is
# appended to $errlog for diagnostics. GNU tar and bsdtar are used unprivileged
# of ownership (--no-same-owner) and are safe against ../ and absolute paths by
# default; bsdtar additionally blocks symlink-target writes.
tar_extract() {
    local dest=$1 archive=$2 prog=$3
    if [[ -n $prog ]]; then
        tar --no-same-owner --use-compress-program="$prog" -x -f "$archive" -C "$dest"
    elif [[ ${archive,,} == *.xz || ${archive,,} == *.txz ]] && (( HAVE_XZ )); then
        XZ_OPT="-T0" tar --no-same-owner -x -f "$archive" -C "$dest"
    elif (( HAVE_BSDTAR )); then
        bsdtar --no-same-owner -x -f "$archive" -C "$dest"
    else
        tar --no-same-owner -x -f "$archive" -C "$dest"
    fi
}

extract_to() {
    local dest=$1 archive=$2 errlog=$3 low=${2,,}
    {
        case "$low" in
            *.zip)
                if   (( HAVE_BSDTAR )); then bsdtar --no-same-owner -x -f "$archive" -C "$dest"
                elif (( HAVE_UNZIP ));  then unzip -qq -o "$archive" -d "$dest"
                elif (( HAVE_7Z ));     then "$SEVENZIP" x -y -bso0 -bsp0 -o"$dest" "$archive"
                else return 2; fi ;;
            *.tar.gz|*.tgz)            tar_extract "$dest" "$archive" "$GZ_PROG" ;;
            *.tar.bz2|*.tbz2)         tar_extract "$dest" "$archive" "$BZ_PROG" ;;
            *.tar.xz|*.txz)           tar_extract "$dest" "$archive" "" ;;
            *.tar.zst|*.tzst)
                if [[ -n $ZSTD_PROG ]]; then tar_extract "$dest" "$archive" "$ZSTD_PROG"
                else tar_extract "$dest" "$archive" ""; fi ;;
            *.tar)                    tar_extract "$dest" "$archive" "" ;;
            *.7z)
                if   (( HAVE_BSDTAR )); then bsdtar --no-same-owner -x -f "$archive" -C "$dest"
                elif (( HAVE_7Z ));     then "$SEVENZIP" x -y -bso0 -bsp0 -o"$dest" "$archive"
                else return 2; fi ;;
            *.rar)
                if   (( HAVE_UNRAR ));  then unrar x -o+ -idq "$archive" "$dest/"
                elif (( HAVE_7Z ));     then "$SEVENZIP" x -y -bso0 -bsp0 -o"$dest" "$archive"
                elif (( HAVE_BSDTAR )); then bsdtar --no-same-owner -x -f "$archive" -C "$dest"
                else return 2; fi ;;
            *)
                if   (( HAVE_BSDTAR )); then bsdtar --no-same-owner -x -f "$archive" -C "$dest"
                elif (( HAVE_7Z ));     then "$SEVENZIP" x -y -bso0 -bsp0 -o"$dest" "$archive"
                else return 2; fi ;;
        esac
    } >/dev/null 2>>"$errlog"
}

# Predict the destination *name* from a listing: the inner root folder for a
# single-root archive, otherwise the archive's base name. Entries are first
# normalized (leading "./" and "/" stripped) so tar archives stored with a "./"
# prefix are read correctly, and a single top of "."/".." (crafted or absolute)
# falls back to the archive base name so the index can never pick the target.
predict_dest_name() {
    local listing=$1 base=$2 tops count
    listing=$(printf '%s\n' "$listing" | sed -E 's#^(\./)+##; s#^/+##' | grep . || true)
    if [[ -z $listing ]]; then printf '%s' "$base"; return; fi
    tops=$(printf '%s\n' "$listing" | sed 's#/.*##' | grep . | sort -u)
    count=$(printf '%s\n' "$tops" | grep -c .)
    if (( count == 1 )) && printf '%s\n' "$listing" | grep -q '/'; then
        case "$tops" in
            ''|.|..) printf '%s' "$base" ;;   # unsafe top -> use archive base
            *)       printf '%s' "$tops" ;;   # single-root: inner folder name
        esac
    else
        printf '%s' "$base"          # flat: name after the archive
    fi
}

# Reject an extracted tree containing a symlink that resolves outside $stage.
symlink_escapes() {
    local stage=$1 stage_real link target
    stage_real=$(realpath -- "$stage" 2>/dev/null) || return 0
    while IFS= read -r -d '' link; do
        target=$(realpath -m -- "$link" 2>/dev/null) || return 0
        case "$target/" in
            "$stage_real/"*) : ;;
            *) return 0 ;;           # escapes -> "unsafe" (function succeeds)
        esac
    done < <(find "$stage" -type l -print0 2>/dev/null)
    return 1                          # no escape found -> safe
}

# Portable byte size: GNU `stat -c`, then BSD/macOS `stat -f`, else 0.
file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0; }

# ------------------------------------------------------------------------------
# Per-archive worker. Records exactly one result line so the parent can tally
# after `wait`. Never propagates failure to the parent (set -e safe): every
# fallible step is guarded.
# ------------------------------------------------------------------------------
process_archive() {
    local archive=$1 idx=$2
    local result="$RESULTS_DIR/$idx"
    local errlog="$RESULTS_DIR/$idx.err"
    local filename base
    filename=$(basename -- "$archive")
    base=$(strip_archive_ext "$filename")

    # 1. Cheap content listing -> corruption check + destination prediction.
    local listing
    listing=$(list_archive "$archive" \
        | grep -Ev '^(__MACOSX|\.DS_Store)(/|$)|/\.DS_Store$|/__MACOSX(/|$)' \
        | grep . || true)
    if [[ -z $listing ]]; then
        log_warn "skip (corrupt/empty): $filename"
        printf 'corrupt\t0\n' >"$result"; return 0
    fi

    local dest_name dest
    dest_name=$(predict_dest_name "$listing" "$base")
    # Never let the destination escape TARGET_DIR or alias it / its parent.
    case "$dest_name" in
        ''|.|..|*/*)
            log_warn "skip (invalid destination name): $filename"
            printf 'corrupt\t0\n' >"$result"; return 0 ;;
    esac
    dest="$TARGET_DIR/$dest_name"

    # 2. Dry-run: report the plan and stop.
    if (( DRY_RUN )); then
        if [[ -e $dest ]]; then
            log_info "would skip (dest exists): $filename -> $dest_name"
            printf 'dup\t0\n' >"$result"
        else
            log_info "would extract: $filename -> $dest_name/"
            printf 'dryrun\t0\n' >"$result"
        fi
        return 0
    fi

    # 3. Atomic dedup claim: reserve the destination before doing any work.
    if ! mkdir "$dest" 2>/dev/null; then
        if (( PRUNE_DUPLICATES )); then
            local sz; sz=$(file_size "$archive")
            rm -f -- "$archive"
            log_warn "duplicate pruned (dest exists): $filename"
            printf 'dup_pruned\t%s\n' "$sz" >"$result"
        else
            log_warn "skip (dest exists): $filename"
            printf 'dup\t0\n' >"$result"
        fi
        return 0
    fi

    # 4. Extract into a private, run-scoped staging dir on the target fs.
    local stage
    if ! stage=$(mktemp -d "$TARGET_DIR/.unzipdupe.stage.$RUNID.XXXXXX" 2>/dev/null); then
        rmdir -- "$dest" 2>/dev/null || true
        log_err "cannot create staging dir for: $filename"
        printf 'failed\t0\n' >"$result"; return 0
    fi

    # Capture the real exit status: `if ! cmd` would mask it to 0, so the
    # rc==2 ("no capable tool") diagnostic must read it via `|| rc=$?`.
    local rc=0
    extract_to "$stage" "$archive" "$errlog" || rc=$?
    if (( rc != 0 )); then
        rmdir -- "$dest" 2>/dev/null || true
        rm -rf -- "$stage"
        if (( rc == 2 )); then
            log_err "no tool to extract: $filename"
        else
            log_err "extraction failed (archive kept): $filename"
            if (( VERBOSE )) && [[ -s $errlog ]]; then log_dbg "$(tail -n1 -- "$errlog")"; fi
        fi
        printf 'failed\t0\n' >"$result"; return 0
    fi

    # 5. Drop macOS cruft so it cannot affect single-root detection or output.
    find "$stage" -depth \( -name '__MACOSX' -o -name '.DS_Store' -o -name '.AppleDouble' \) \
        -exec rm -rf -- {} + 2>/dev/null || true

    # 6. Security: reject trees with symlinks escaping the staging dir.
    if symlink_escapes "$stage"; then
        rmdir -- "$dest" 2>/dev/null || true
        rm -rf -- "$stage"
        log_err "unsafe (symlink escapes archive root, kept): $filename"
        printf 'unsafe\t0\n' >"$result"; return 0
    fi

    # 7. Collapse a sole top-level directory (authoritative, from filesystem).
    local -a top
    shopt -s nullglob dotglob
    top=( "$stage"/* )
    local src=$stage
    # Collapse only into a *real* sole directory; a sole symlink must not be
    # descended (globbing through it would move its targets, not the entry).
    if (( ${#top[@]} == 1 )) && [[ -d ${top[0]} && ! -L ${top[0]} ]]; then src=${top[0]}; fi
    local -a items=( "$src"/* )
    shopt -u nullglob dotglob

    if (( ${#items[@]} == 0 )); then
        rmdir -- "$dest" 2>/dev/null || true
        rm -rf -- "$stage"
        log_warn "skip (nothing to extract): $filename"
        printf 'corrupt\t0\n' >"$result"; return 0
    fi

    # 8. Place the content into the claimed destination (renames, same fs).
    if ! mv -- "${items[@]}" "$dest"/ 2>>"$errlog"; then
        # We created $dest this run, so removing it rolls back cleanly and lets
        # a future run retry instead of seeing a half-populated "duplicate".
        rm -rf -- "$dest" "$stage"
        log_err "placement failed (rolled back, archive kept): $filename"
        printf 'failed\t0\n' >"$result"; return 0
    fi
    rm -rf -- "$stage"

    # 9. Success -> retire the source archive (unless --keep).
    local sz; sz=$(file_size "$archive")
    if (( KEEP )); then
        log_ok "extracted (kept): $filename -> $dest_name/"
        printf 'ok_kept\t0\n' >"$result"
    else
        rm -f -- "$archive"
        log_ok "extracted: $filename -> $dest_name/"
        printf 'ok\t%s\n' "$sz" >"$result"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
RESULTS_DIR=""
RUNID=""
cleanup() {
    local code=$?
    if [[ -n $RESULTS_DIR && -d $RESULTS_DIR ]]; then rm -rf -- "$RESULTS_DIR"; fi
    # Remove only THIS run's staging dirs (scoped by RUNID) so a concurrent
    # run against the same target is never disturbed.
    if [[ -n ${RUNID:-} && -n ${TARGET_DIR:-} && -d ${TARGET_DIR:-} ]]; then
        local d
        shopt -s nullglob
        for d in "$TARGET_DIR"/.unzipdupe.stage."$RUNID".*; do rm -rf -- "$d"; done
        shopt -u nullglob
    fi
    return $code
}
on_interrupt() {
    log_err "interrupt -- terminating workers and rolling back staging dirs..."
    trap - INT TERM
    # Kill only our own background workers (no process-group blast radius).
    local -a pids
    mapfile -t pids < <(jobs -p)
    if (( ${#pids[@]} )); then kill "${pids[@]}" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    exit 130
}

# ------------------------------------------------------------------------------
# Human-readable byte formatter
# ------------------------------------------------------------------------------
human_bytes() {
    local b=${1:-0} u=(B KiB MiB GiB TiB) i=0
    while (( b >= 1024 && i < 4 )); do b=$(( b / 1024 )); i=$((i+1)); done
    printf '%s %s' "$b" "${u[$i]}"
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
UnzipDupe.sh -- parallel, safe, dedup-aware bulk archive extractor

Usage: $(basename -- "$0") [options] [TARGET_DIR]

Extracts every archive in TARGET_DIR (non-recursive). An archive that wraps a
single top-level folder is placed as TARGET_DIR/<folder>/; otherwise its files
go into TARGET_DIR/<archive-base-name>/. An archive whose destination already
exists is skipped (dedup). Source archives are deleted after a successful
extraction unless --keep is given.

Options:
  -j, --jobs N          Parallel workers (default: nproc).
  -k, --keep            Keep source archives after extraction.
  -n, --dry-run         Show what would happen; change nothing.
      --prune-duplicates  Delete a source archive whose destination exists.
  -q, --quiet           Only warnings, errors and the final summary.
  -v, --verbose         Extra per-archive diagnostics.
      --color=WHEN      auto (default), always, or never.
  -h, --help            This help.

TARGET_DIR defaults to: $DEFAULT_TARGET_DIR
Supported: .zip .7z .rar .tar .tar.gz/.tgz .tar.bz2/.tbz2 .tar.xz/.txz
           .tar.zst/.tzst   (handlers auto-detected at runtime)
EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_args() {
    while (( $# )); do
        case "$1" in
            -j|--jobs)        JOBS=${2:-}; shift 2 ;;
            --jobs=*)         JOBS=${1#*=}; shift ;;
            -j*)              JOBS=${1#-j}; shift ;;
            -k|--keep)        KEEP=1; shift ;;
            -n|--dry-run)     DRY_RUN=1; shift ;;
            --prune-duplicates) PRUNE_DUPLICATES=1; shift ;;
            -q|--quiet)       QUIET=1; shift ;;
            -v|--verbose)     VERBOSE=1; shift ;;
            --color)          COLOR_MODE=${2:-auto}; shift 2 ;;
            --color=*)        COLOR_MODE=${1#*=}; shift ;;
            -h|--help)        usage; exit 0 ;;
            --)               shift; [[ $# -gt 0 ]] && TARGET_DIR=$1; break ;;
            -*)               usage >&2; die "unknown option: $1" ;;
            *)                TARGET_DIR=$1; shift ;;
        esac
    done
    [[ -n $TARGET_DIR ]] || TARGET_DIR=$DEFAULT_TARGET_DIR
    TARGET_DIR=${TARGET_DIR%/}
    [[ -z $JOBS ]] && JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    [[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer (got: $JOBS)"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"
    setup_colors
    detect_tools

    [[ -d $TARGET_DIR ]] || die "target directory does not exist: $TARGET_DIR"

    # Gather archives (NUL-safe, non-recursive, skip our own staging dirs).
    local -a archives=()
    local f
    while IFS= read -r -d '' f; do archives+=("$f"); done < <(
        find "$TARGET_DIR" -maxdepth 1 -type f \( \
            -iname '*.zip'     -o -iname '*.7z'      -o -iname '*.rar'    -o \
            -iname '*.tar'     -o -iname '*.tar.gz'  -o -iname '*.tgz'    -o \
            -iname '*.tar.xz'  -o -iname '*.txz'     -o -iname '*.tar.bz2' -o \
            -iname '*.tbz2'    -o -iname '*.tar.zst' -o -iname '*.tzst'   \
        \) -print0 2>/dev/null)

    if (( ${#archives[@]} == 0 )); then
        log_info "no archives found in: $TARGET_DIR"
        exit 0
    fi

    RESULTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/unzipdupe.run.XXXXXX")
    RUNID=$(basename -- "$RESULTS_DIR")
    trap cleanup EXIT
    trap on_interrupt INT TERM

    log_info "target: $TARGET_DIR"
    log_info "workers: $JOBS | archives: ${#archives[@]}${DRY_RUN:+ | DRY-RUN}"
    log_dbg "extractors: bsdtar=$HAVE_BSDTAR 7z=${SEVENZIP:-none} unzip=$HAVE_UNZIP unrar=$HAVE_UNRAR"
    log_dbg "decompressors: gz=${GZ_PROG:-builtin} bz2=${BZ_PROG:-builtin} xz=$([[ $HAVE_XZ == 1 ]] && echo 'xz -T0' || echo builtin) zst=${ZSTD_PROG:-builtin}"

    local start=$SECONDS

    # Bounded worker pool: at most $JOBS workers run at once. We block on a
    # blocking `wait -n` (no busy-wait, no per-iteration subshell) BEFORE each
    # spawn, so the cap is honored strictly rather than transiently exceeded.
    local i running=0
    for (( i=0; i<${#archives[@]}; i++ )); do
        if (( running >= JOBS )); then wait -n 2>/dev/null || true; running=$((running - 1)); fi
        process_archive "${archives[$i]}" "$i" &
        running=$((running + 1))
    done
    wait

    # Tally results.
    local ok=0 ok_kept=0 dup=0 dup_pruned=0 corrupt=0 failed=0 unsafe=0 dry=0
    local reclaimed=0 status sz
    for (( i=0; i<${#archives[@]}; i++ )); do
        [[ -f "$RESULTS_DIR/$i" ]] || { failed=$((failed+1)); continue; }
        IFS=$'\t' read -r status sz <"$RESULTS_DIR/$i" || true
        case "$status" in
            ok)         ok=$((ok+1)); reclaimed=$((reclaimed + ${sz:-0})) ;;
            ok_kept)    ok_kept=$((ok_kept+1)) ;;
            dup)        dup=$((dup+1)) ;;
            dup_pruned) dup_pruned=$((dup_pruned+1)); reclaimed=$((reclaimed + ${sz:-0})) ;;
            corrupt)    corrupt=$((corrupt+1)) ;;
            unsafe)     unsafe=$((unsafe+1)) ;;
            dryrun)     dry=$((dry+1)) ;;
            *)          failed=$((failed+1)) ;;
        esac
    done

    local elapsed=$(( SECONDS - start ))
    log_info "------------------------------------------------------------"
    if (( DRY_RUN )); then
        log_info "DRY-RUN summary: would extract $dry, would skip $dup (elapsed ${elapsed}s)"
    else
        log_info "Done in ${elapsed}s: extracted $ok$( ((ok_kept)) && printf ' (+%s kept)' "$ok_kept"), \
skipped $dup dup$( ((dup_pruned)) && printf ', pruned %s' "$dup_pruned"), \
corrupt $corrupt, unsafe $unsafe, failed $failed"
        log_info "reclaimed: $(human_bytes "$reclaimed")"
    fi
    (( failed + unsafe == 0 ))
}

# Only auto-run when executed directly, not when sourced (keeps `kill`/traps
# from affecting a parent shell that sources this file).
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
