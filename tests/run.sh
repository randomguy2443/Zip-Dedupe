#!/usr/bin/env bash
# Functional test suite for UnzipDupe.sh.
# Self-contained: builds sample inputs in a temp dir, runs the script, and
# asserts behavior. Each format is guarded by tool availability, so the suite
# runs anywhere and only exercises formats whose tools are installed.
#
# Usage: bash tests/run.sh

set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$HERE/../UnzipDupe.sh"
[[ -f $SCRIPT ]] || { echo "cannot find UnzipDupe.sh at $SCRIPT" >&2; exit 2; }

PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# t "description" <command...>  -- assert the command succeeds
t() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
isf() { [[ -f $1 ]]; }
absent() { [[ ! -e $1 ]]; }
allf() { local x; for x in "$@"; do [[ -f $x ]] || return 1; done; return 0; }
streq() { [[ $1 == "$2" ]]; }
nostage() { ! compgen -G "$T/.unzipdupe.stage.*" >/dev/null; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/unzipdupe.test.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
SRC="$WORK/src"; T="$WORK/target"; mkdir -p "$SRC" "$T"

run() { bash "$SCRIPT" --color=never "$@"; }

# ---------------------------------------------------------------------------
# Fixtures (only those whose tools exist)
# ---------------------------------------------------------------------------
# single-root zip -> proj/
mkdir -p "$SRC/proj/sub"; echo a >"$SRC/proj/a.txt"; echo b >"$SRC/proj/sub/b.txt"
have zip && ( cd "$SRC" && zip -qr "$T/proj.zip" proj )
# flat zip (multiple top-level) -> flatzip/
mkdir -p "$SRC/flat"; echo 1 >"$SRC/flat/one.txt"; echo 2 >"$SRC/flat/two.txt"
have zip && ( cd "$SRC/flat" && zip -q "$T/flatzip.zip" one.txt two.txt )
# single-root tar.gz -> tgzroot/
mkdir -p "$SRC/tgzroot/x"; echo g >"$SRC/tgzroot/x/g.txt"
tar -C "$SRC" -czf "$T/tgzroot.tar.gz" tgzroot
# ./-prefixed flat tar -> dotflat/
mkdir -p "$SRC/dotflat"; echo p >"$SRC/dotflat/p.txt"; echo q >"$SRC/dotflat/q.txt"
( cd "$SRC/dotflat" && tar -cf "$T/dotflat.tar" . )
# 7z single-root -> seven/
mkdir -p "$SRC/seven/d"; echo z >"$SRC/seven/d/z.txt"
if   have 7z;  then ( cd "$SRC" && 7z  a -bso0 -bsp0 "$T/seven.7z" seven >/dev/null )
elif have 7zz; then ( cd "$SRC" && 7zz a -bso0 -bsp0 "$T/seven.7z" seven >/dev/null )
elif have 7za; then ( cd "$SRC" && 7za a "$T/seven.7z" seven >/dev/null ); fi
# bare single-file compressors
printf 'GZBYTES\n' >"$SRC/g.bin"; have gzip  && gzip  -c "$SRC/g.bin" >"$T/g.bin.gz"
printf 'BZBYTES\n' >"$SRC/h.bin"; have bzip2 && bzip2 -c "$SRC/h.bin" >"$T/h.bin.bz2"
printf 'XZBYTES\n' >"$SRC/i.bin"; have xz    && xz    -c "$SRC/i.bin" >"$T/i.bin.xz"
printf 'ZSBYTES\n' >"$SRC/j.bin"; have zstd  && zstd -qc "$SRC/j.bin" >"$T/j.bin.zst"
printf 'L4BYTES\n' >"$SRC/k.bin"; have lz4   && lz4  -qc "$SRC/k.bin" >"$T/k.bin.lz4"
# tar hidden inside a bare .gz (no .tar in the name) -> auto-extract to secret/
printf '1\n' >"$SRC/f1"; printf '2\n' >"$SRC/f2"; tar -C "$SRC" -cf "$WORK/in.tar" f1 f2
have gzip && gzip -c "$WORK/in.tar" >"$T/secret.gz"
# dedup: pre-existing destination kept, source kept, not re-extracted
mkdir -p "$SRC/dupe/h"; echo d >"$SRC/dupe/h/d.txt"; have zip && ( cd "$SRC" && zip -qr "$T/dupe.zip" dupe )
mkdir -p "$T/dupe"; echo preexisting >"$T/dupe/EXISTING.txt"
# corrupt archive -> kept, not extracted
head -c 200 /dev/urandom >"$T/corrupt.zip"
# symlink escape -> rejected, source kept, not placed
mkdir -p "$SRC/evilroot"; ln -sf /etc/passwd "$SRC/evilroot/evil"; tar -C "$SRC" -cf "$T/evil.tar" evilroot

# ---------------------------------------------------------------------------
# Dry-run must change nothing
# ---------------------------------------------------------------------------
before=$(find "$T" -mindepth 1 | sort)
run --dry-run "$T" >/dev/null 2>&1
after=$(find "$T" -mindepth 1 | sort)
t "dry-run changes nothing" streq "$before" "$after"

# ---------------------------------------------------------------------------
# Real run
# ---------------------------------------------------------------------------
run -j4 "$T" >/dev/null 2>&1 || true

if have zip; then
    t "single-root zip -> proj/a.txt"     allf "$T/proj/a.txt" "$T/proj/sub/b.txt"
    t "proj not double-nested"            absent "$T/proj/proj"
    t "proj.zip deleted"                  absent "$T/proj.zip"
    t "flat zip -> flatzip/{one,two}.txt" allf "$T/flatzip/one.txt" "$T/flatzip/two.txt"
    t "dedup: pre-existing kept"          isf "$T/dupe/EXISTING.txt"
    t "dedup: not re-extracted"           absent "$T/dupe/h"
    t "dedup: source kept"                isf "$T/dupe.zip"
fi
t "tar.gz single-root -> tgzroot/x/g.txt" isf "$T/tgzroot/x/g.txt"
t "./-prefixed flat tar -> dotflat/{p,q}" allf "$T/dotflat/p.txt" "$T/dotflat/q.txt"
if have 7z || have 7zz || have 7za; then
    t "7z single-root -> seven/d/z.txt"   isf "$T/seven/d/z.txt"
fi

if have gzip; then
    t "gz -> g.bin content"  streq "$(cat "$T/g.bin" 2>/dev/null)" GZBYTES
    t "gz source deleted"    absent "$T/g.bin.gz"
fi
have bzip2 && t "bz2 -> h.bin content" streq "$(cat "$T/h.bin" 2>/dev/null)" BZBYTES
have xz    && t "xz -> i.bin content"  streq "$(cat "$T/i.bin" 2>/dev/null)" XZBYTES
have zstd  && t "zst -> j.bin content" streq "$(cat "$T/j.bin" 2>/dev/null)" ZSBYTES
have lz4   && t "lz4 -> k.bin content" streq "$(cat "$T/k.bin" 2>/dev/null)" L4BYTES
if have gzip; then
    t "tar-in-gz auto-extract -> secret/{f1,f2}" allf "$T/secret/f1" "$T/secret/f2"
    t "tar-in-gz source deleted"                 absent "$T/secret.gz"
fi

t "corrupt.zip kept"            isf "$T/corrupt.zip"
t "corrupt not extracted"       absent "$T/corrupt"
t "symlink-escape source kept"  isf "$T/evil.tar"
t "symlink-escape not placed"   absent "$T/evilroot"
t "no leftover staging dirs"    nostage

# --keep retains source
mkdir -p "$SRC/keep/k"; echo kk >"$SRC/keep/k/k.txt"; tar -C "$SRC" -czf "$T/keep.tar.gz" keep
run --keep "$T" >/dev/null 2>&1 || true
t "--keep extracts"      isf "$T/keep/k/k.txt"
t "--keep retains source" isf "$T/keep.tar.gz"

echo
echo "=================== RESULTS: PASS=$PASS FAIL=$FAIL ==================="
[[ $FAIL -eq 0 ]]
