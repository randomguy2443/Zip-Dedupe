#!/usr/bin/env bash
# UnzipDupe.sh -- parallel, safe, dedup-aware bulk archive extractor.
# Extracts every archive in a target directory (default: current dir), skips an
# archive whose destination already exists, and deletes each source on success.
# Run with --help for options.

set -euo pipefail

DEFAULT_TARGET_DIR="."

TARGET_DIR=""
JOBS=""
KEEP=0
DRY_RUN=0
PRUNE_DUPLICATES=0
QUIET=0
VERBOSE=0
COLOR_MODE="auto"

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

log_info() { (( QUIET )) || printf '%s[*]%s %s\n' "$CLR_INFO" "$CLR_RESET" "$*" >&2; }
log_ok()   { (( QUIET )) || printf '%s[+]%s %s\n' "$CLR_OK"   "$CLR_RESET" "$*" >&2; }
log_warn() {              printf '%s[!]%s %s\n' "$CLR_WARN" "$CLR_RESET" "$*" >&2; }
log_err()  {              printf '%s[x]%s %s\n' "$CLR_ERR"  "$CLR_RESET" "$*" >&2; }
log_dbg()  { (( VERBOSE )) || return 0; printf '%s[.] %s%s\n' "$CLR_DIM" "$*" "$CLR_RESET" >&2; }

die() { log_err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

HAVE_BSDTAR=0 HAVE_7Z=0 HAVE_UNZIP=0 HAVE_UNRAR=0
HAVE_PIGZ=0 HAVE_LBZIP2=0 HAVE_PBZIP2=0 HAVE_ZSTD=0 HAVE_XZ=0 HAVE_LZ4=0
SEVENZIP=""
GZ_PROG="" BZ_PROG="" ZSTD_PROG=""

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
    have lz4    && HAVE_LZ4=1

    (( HAVE_PIGZ )) && GZ_PROG="pigz"
    if   (( HAVE_LBZIP2 )); then BZ_PROG="lbzip2"
    elif (( HAVE_PBZIP2 )); then BZ_PROG="pbzip2"; fi
    (( HAVE_ZSTD )) && ZSTD_PROG="zstd"

    have tar || (( HAVE_BSDTAR )) || die "neither 'tar' nor 'bsdtar' is available"
}

strip_archive_ext() {
    local f=$1 low=${1,,} ext
    for ext in .tar.gz .tar.xz .tar.bz2 .tar.zst .tgz .txz .tbz2 .tzst .tar .zip .7z .rar; do
        if [[ $low == *"$ext" ]]; then printf '%s' "${f:0:${#f}-${#ext}}"; return; fi
    done
    printf '%s' "$f"
}

strip_compressor_ext() {
    local f=$1 low=${1,,} ext
    for ext in .gz .bz2 .xz .zst .lz4 .lzma .z; do
        if [[ $low == *"$ext" ]]; then printf '%s' "${f:0:${#f}-${#ext}}"; return; fi
    done
    printf '%s' "$f"
}

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
            *.tar.gz|*.tgz)   tar_extract "$dest" "$archive" "$GZ_PROG" ;;
            *.tar.bz2|*.tbz2) tar_extract "$dest" "$archive" "$BZ_PROG" ;;
            *.tar.xz|*.txz)   tar_extract "$dest" "$archive" "" ;;
            *.tar.zst|*.tzst)
                if [[ -n $ZSTD_PROG ]]; then tar_extract "$dest" "$archive" "$ZSTD_PROG"
                else tar_extract "$dest" "$archive" ""; fi ;;
            *.tar)            tar_extract "$dest" "$archive" "" ;;
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

decompress_stream() {
    local low=${1,,}
    case "$low" in
        *.gz|*.z)
            if (( HAVE_PIGZ )); then pigz -dc -- "$1"; elif have gzip; then gzip -dc -- "$1"; else return 2; fi ;;
        *.bz2)
            if   (( HAVE_LBZIP2 )); then lbzip2 -dc -- "$1"
            elif (( HAVE_PBZIP2 )); then pbzip2 -dc -- "$1"
            elif have bzip2;        then bzip2 -dc -- "$1"
            else return 2; fi ;;
        *.xz|*.lzma)
            if (( HAVE_XZ )); then xz -dc -T0 -- "$1"; else return 2; fi ;;
        *.zst)
            if (( HAVE_ZSTD )); then zstd -dc -- "$1"; else return 2; fi ;;
        *.lz4)
            if (( HAVE_LZ4 )); then lz4 -dc -- "$1"; else return 2; fi ;;
        *) return 2 ;;
    esac
}

is_tar() {
    if (( HAVE_BSDTAR )); then bsdtar -tf "$1" >/dev/null 2>&1
    else tar -tf "$1" >/dev/null 2>&1; fi
}

predict_dest_name() {
    local listing=$1 base=$2 tops count
    listing=$(printf '%s\n' "$listing" | sed -E 's#^(\./)+##; s#^/+##' | grep . || true)
    if [[ -z $listing ]]; then printf '%s' "$base"; return; fi
    tops=$(printf '%s\n' "$listing" | sed 's#/.*##' | grep . | sort -u)
    count=$(printf '%s\n' "$tops" | grep -c .)
    if (( count == 1 )) && printf '%s\n' "$listing" | grep -q '/'; then
        case "$tops" in
            ''|.|..) printf '%s' "$base" ;;
            *)       printf '%s' "$tops" ;;
        esac
    else
        printf '%s' "$base"
    fi
}

symlink_escapes() {
    local stage=$1 stage_real link target
    stage_real=$(realpath -- "$stage" 2>/dev/null) || return 0
    while IFS= read -r -d '' link; do
        target=$(realpath -m -- "$link" 2>/dev/null) || return 0
        case "$target/" in
            "$stage_real/"*) : ;;
            *) return 0 ;;
        esac
    done < <(find "$stage" -type l -print0 2>/dev/null)
    return 1
}

file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0; }

new_stage() { mktemp -d "$TARGET_DIR/.unzipdupe.stage.$RUNID.XXXXXX" 2>/dev/null; }

record_dup() {
    local result=$1 archive=$2 filename=$3
    if (( PRUNE_DUPLICATES )); then
        local sz; sz=$(file_size "$archive"); rm -f -- "$archive"
        log_warn "duplicate pruned (dest exists): $filename"
        printf 'dup_pruned\t%s\n' "$sz" >"$result"
    else
        log_warn "skip (dest exists): $filename"
        printf 'dup\t0\n' >"$result"
    fi
}

record_ok() {
    local result=$1 archive=$2 filename=$3 label=$4
    local sz; sz=$(file_size "$archive")
    if (( KEEP )); then
        log_ok "extracted (kept): $filename -> $label"
        printf 'ok_kept\t0\n' >"$result"
    else
        rm -f -- "$archive"
        log_ok "extracted: $filename -> $label"
        printf 'ok\t%s\n' "$sz" >"$result"
    fi
}

# Move the contents of a populated $stage into an already-claimed (empty) $dest,
# collapsing a sole top-level directory. On any failure $dest and $stage are
# removed. Returns: 0 ok, 1 unsafe (symlink escape), 2 empty, 3 placement error.
finalize_stage_into_dest() {
    local stage=$1 dest=$2
    find "$stage" -depth \( -name '__MACOSX' -o -name '.DS_Store' -o -name '.AppleDouble' \) \
        -exec rm -rf -- {} + 2>/dev/null || true
    if symlink_escapes "$stage"; then rm -rf -- "$dest" "$stage"; return 1; fi
    local -a top items
    shopt -s nullglob dotglob
    top=( "$stage"/* )
    local src=$stage
    if (( ${#top[@]} == 1 )) && [[ -d ${top[0]} && ! -L ${top[0]} ]]; then src=${top[0]}; fi
    items=( "$src"/* )
    shopt -u nullglob dotglob
    if (( ${#items[@]} == 0 )); then rm -rf -- "$dest" "$stage"; return 2; fi
    if ! mv -- "${items[@]}" "$dest"/ 2>/dev/null; then rm -rf -- "$dest" "$stage"; return 3; fi
    rm -rf -- "$stage"
    return 0
}

report_finalize() {
    local fr=$1 result=$2 archive=$3 filename=$4 label=$5
    case "$fr" in
        0) record_ok "$result" "$archive" "$filename" "$label" ;;
        1) log_err "unsafe (symlink escapes archive root, kept): $filename"; printf 'unsafe\t0\n' >"$result" ;;
        2) log_warn "skip (nothing to extract): $filename"; printf 'corrupt\t0\n' >"$result" ;;
        *) log_err "placement failed (rolled back, archive kept): $filename"; printf 'failed\t0\n' >"$result" ;;
    esac
}

handle_archive() {
    local archive=$1 result=$2 errlog=$3 filename=$4
    local base; base=$(strip_archive_ext "$filename")

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
    case "$dest_name" in
        ''|.|..|*/*)
            log_warn "skip (invalid destination name): $filename"
            printf 'corrupt\t0\n' >"$result"; return 0 ;;
    esac
    dest="$TARGET_DIR/$dest_name"

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

    if ! mkdir "$dest" 2>/dev/null; then record_dup "$result" "$archive" "$filename"; return 0; fi

    local stage
    if ! stage=$(new_stage); then
        rmdir -- "$dest" 2>/dev/null || true
        log_err "cannot create staging dir for: $filename"
        printf 'failed\t0\n' >"$result"; return 0
    fi

    local rc=0
    extract_to "$stage" "$archive" "$errlog" || rc=$?
    if (( rc != 0 )); then
        rmdir -- "$dest" 2>/dev/null || true
        rm -rf -- "$stage"
        if (( rc == 2 )); then log_err "no tool to extract: $filename"
        else log_err "extraction failed (archive kept): $filename"; fi
        printf 'failed\t0\n' >"$result"; return 0
    fi

    local fr=0; finalize_stage_into_dest "$stage" "$dest" || fr=$?
    report_finalize "$fr" "$result" "$archive" "$filename" "$dest_name/"
    return 0
}

handle_compressed() {
    local archive=$1 result=$2 errlog=$3 filename=$4
    local inner; inner=$(strip_compressor_ext "$filename")
    case "$inner" in
        ''|.|..|*/*)
            log_warn "skip (invalid name): $filename"
            printf 'corrupt\t0\n' >"$result"; return 0 ;;
    esac

    if (( DRY_RUN )); then
        if [[ -e "$TARGET_DIR/$inner" ]]; then
            log_info "would skip (exists): $filename -> $inner"
            printf 'dup\t0\n' >"$result"
        else
            log_info "would decompress: $filename -> $inner (extract if it is a tar)"
            printf 'dryrun\t0\n' >"$result"
        fi
        return 0
    fi

    local stage
    if ! stage=$(new_stage); then
        log_err "cannot create staging dir for: $filename"
        printf 'failed\t0\n' >"$result"; return 0
    fi

    local out="$stage/$inner" rc=0
    decompress_stream "$archive" >"$out" 2>>"$errlog" || rc=$?
    if (( rc != 0 )); then
        rm -rf -- "$stage"
        if (( rc == 2 )); then log_err "no tool to decompress: $filename"
        else log_err "decompression failed (kept): $filename"; fi
        printf 'failed\t0\n' >"$result"; return 0
    fi

    if is_tar "$out"; then
        local tname=$inner
        case "${inner,,}" in *.tar) tname=${inner:0:${#inner}-4} ;; esac
        case "$tname" in ''|.|..|*/*) tname=$inner ;; esac
        local dest="$TARGET_DIR/$tname"
        if ! mkdir "$dest" 2>/dev/null; then
            record_dup "$result" "$archive" "$filename"; rm -rf -- "$stage"; return 0
        fi
        local sub
        if ! sub=$(new_stage); then
            rmdir -- "$dest" 2>/dev/null || true; rm -rf -- "$stage"
            log_err "cannot create staging dir for: $filename"
            printf 'failed\t0\n' >"$result"; return 0
        fi
        local er=0
        { if (( HAVE_BSDTAR )); then bsdtar --no-same-owner -x -f "$out" -C "$sub"
          else tar --no-same-owner -x -f "$out" -C "$sub"; fi; } >/dev/null 2>>"$errlog" || er=$?
        rm -rf -- "$stage"
        if (( er != 0 )); then
            rmdir -- "$dest" 2>/dev/null || true; rm -rf -- "$sub"
            log_err "extraction failed (archive kept): $filename"
            printf 'failed\t0\n' >"$result"; return 0
        fi
        local fr=0; finalize_stage_into_dest "$sub" "$dest" || fr=$?
        report_finalize "$fr" "$result" "$archive" "$filename" "$tname/"
        return 0
    fi

    local dest="$TARGET_DIR/$inner"
    if [[ -e $dest ]]; then record_dup "$result" "$archive" "$filename"; rm -rf -- "$stage"; return 0; fi
    if ln -- "$out" "$dest" 2>/dev/null; then
        rm -rf -- "$stage"; record_ok "$result" "$archive" "$filename" "$inner"
    elif [[ ! -e $dest ]] && mv -- "$out" "$dest" 2>/dev/null; then
        rm -rf -- "$stage"; record_ok "$result" "$archive" "$filename" "$inner"
    else
        rm -rf -- "$stage"; record_dup "$result" "$archive" "$filename"
    fi
    return 0
}

process_archive() {
    local archive=$1 idx=$2
    local result="$RESULTS_DIR/$idx" errlog="$RESULTS_DIR/$idx.err"
    local filename; filename=$(basename -- "$archive")
    case "${filename,,}" in
        *.zip|*.7z|*.rar|*.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tar.zst|*.tzst)
            handle_archive "$archive" "$result" "$errlog" "$filename" ;;
        *.gz|*.bz2|*.xz|*.zst|*.lz4|*.lzma|*.z)
            handle_compressed "$archive" "$result" "$errlog" "$filename" ;;
        *)
            handle_archive "$archive" "$result" "$errlog" "$filename" ;;
    esac
}

RESULTS_DIR=""
RUNID=""
cleanup() {
    local code=$?
    if [[ -n $RESULTS_DIR && -d $RESULTS_DIR ]]; then rm -rf -- "$RESULTS_DIR"; fi
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
    local -a pids
    mapfile -t pids < <(jobs -p)
    if (( ${#pids[@]} )); then kill "${pids[@]}" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    exit 130
}

human_bytes() {
    local b=${1:-0} u=(B KiB MiB GiB TiB) i=0
    while (( b >= 1024 && i < 4 )); do b=$(( b / 1024 )); i=$((i+1)); done
    printf '%s %s' "$b" "${u[$i]}"
}

usage() {
    cat <<EOF
UnzipDupe.sh -- parallel, safe, dedup-aware bulk archive extractor

Usage: $(basename -- "$0") [options] [TARGET_DIR]

Extracts every archive in TARGET_DIR (non-recursive; default: current dir).
A multi-file archive lands in TARGET_DIR/<name>/; a bare single-file compressor
(e.g. foo.pdf.gz) decompresses to TARGET_DIR/foo.pdf. Destinations that already
exist are skipped (dedup). Sources are deleted on success unless --keep.

Options:
  -j, --jobs N            Parallel workers (default: nproc).
  -k, --keep              Keep source archives after extraction.
  -n, --dry-run           Show what would happen; change nothing.
      --prune-duplicates  Delete a source whose destination already exists.
  -q, --quiet             Only warnings, errors and the final summary.
  -v, --verbose           Extra per-archive diagnostics.
      --color=WHEN        auto (default), always, or never.
  -h, --help              This help.

Archives:  .zip .7z .rar .tar .tar.gz/.tgz .tar.bz2/.tbz2 .tar.xz/.txz .tar.zst/.tzst
Single file: .gz .bz2 .xz .zst .lz4 .lzma .Z  (auto-extracted if they contain a tar)
Handlers are auto-detected; parallel decompressors (pigz/lbzip2/zstd/xz -T0) used when present.
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -j|--jobs)          JOBS=${2:-}; shift 2 ;;
            --jobs=*)           JOBS=${1#*=}; shift ;;
            -j*)                JOBS=${1#-j}; shift ;;
            -k|--keep)          KEEP=1; shift ;;
            -n|--dry-run)       DRY_RUN=1; shift ;;
            --prune-duplicates) PRUNE_DUPLICATES=1; shift ;;
            -q|--quiet)         QUIET=1; shift ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            --color)            COLOR_MODE=${2:-auto}; shift 2 ;;
            --color=*)          COLOR_MODE=${1#*=}; shift ;;
            -h|--help)          usage; exit 0 ;;
            --)                 shift; [[ $# -gt 0 ]] && TARGET_DIR=$1; break ;;
            -*)                 usage >&2; die "unknown option: $1" ;;
            *)                  TARGET_DIR=$1; shift ;;
        esac
    done
    [[ -n $TARGET_DIR ]] || TARGET_DIR=$DEFAULT_TARGET_DIR
    [[ $TARGET_DIR == / ]] || TARGET_DIR=${TARGET_DIR%/}
    [[ -z $JOBS ]] && JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    [[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer (got: $JOBS)"
}

main() {
    parse_args "$@"
    setup_colors
    detect_tools

    [[ -d $TARGET_DIR ]] || die "target directory does not exist: $TARGET_DIR"

    local -a archives=()
    local f
    while IFS= read -r -d '' f; do archives+=("$f"); done < <(
        find "$TARGET_DIR" -maxdepth 1 -type f \( \
            -iname '*.zip'  -o -iname '*.7z'   -o -iname '*.rar'  -o -iname '*.tar'  -o \
            -iname '*.tgz'  -o -iname '*.txz'  -o -iname '*.tbz2' -o -iname '*.tzst' -o \
            -iname '*.gz'   -o -iname '*.bz2'  -o -iname '*.xz'   -o -iname '*.zst'  -o \
            -iname '*.lz4'  -o -iname '*.lzma' -o -iname '*.Z'    \
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
    log_info "workers: $JOBS | archives: ${#archives[@]}$( ((DRY_RUN)) && printf ' | DRY-RUN')"
    log_dbg "extractors: bsdtar=$HAVE_BSDTAR 7z=${SEVENZIP:-none} unzip=$HAVE_UNZIP unrar=$HAVE_UNRAR"
    log_dbg "decompressors: gz=${GZ_PROG:-builtin} bz2=${BZ_PROG:-builtin} xz=$([[ $HAVE_XZ == 1 ]] && echo 'xz -T0' || echo builtin) zst=${ZSTD_PROG:-builtin} lz4=$HAVE_LZ4"

    local start=$SECONDS

    local i running=0
    for (( i=0; i<${#archives[@]}; i++ )); do
        if (( running >= JOBS )); then wait -n 2>/dev/null || true; running=$((running - 1)); fi
        process_archive "${archives[$i]}" "$i" &
        running=$((running + 1))
    done
    wait

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
        log_info "DRY-RUN summary: would process $dry, would skip $dup (elapsed ${elapsed}s)"
    else
        log_info "Done in ${elapsed}s: extracted $ok$( ((ok_kept)) && printf ' (+%s kept)' "$ok_kept"), \
skipped $dup dup$( ((dup_pruned)) && printf ', pruned %s' "$dup_pruned"), \
corrupt $corrupt, unsafe $unsafe, failed $failed"
        log_info "reclaimed: $(human_bytes "$reclaimed")"
    fi
    (( failed + unsafe == 0 ))
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
