#!/bin/sh
# Fetch the DOS toolchain (Borland TASM 4.1) used by the reproducible build.
# TASM is Borland/Embarcadero abandonware preserved on archive.org; it is NOT
# committed to this repository. See build/README.md for provenance notes and
# why TLINK is not needed (build/omf2com.py replaces the link step).
set -e
DIR="$(dirname "$0")/toolchain"
mkdir -p "$DIR"
ITEM="tasm_20221214_194938_113157"
SHA_TASM="cafc42bbd1df39ab36e775be74ccb82c0a80da7d2a6dff4dcc2f16ba0e220f95"

fetch() { # file dest
    for base in "https://archive.org/download/$ITEM" \
                "https://dn720001.ca.archive.org/0/items/$ITEM"; do
        for try in 1 2 3 4; do
            if curl -sSL --retry 2 -o "$2" "$base/$1" \
               && [ "$(head -c2 "$2")" = "MZ" ]; then
                return 0
            fi
            sleep 3
        done
    done
    echo "download failed: $1" >&2
    return 1
}

if [ ! -f "$DIR/TASM.EXE" ] || ! echo "$SHA_TASM  $DIR/TASM.EXE" | sha256sum -c - >/dev/null 2>&1; then
    fetch TASM.EXE "$DIR/TASM.EXE"
    echo "$SHA_TASM  $DIR/TASM.EXE" | sha256sum -c -
fi
echo "toolchain ready in $DIR"
