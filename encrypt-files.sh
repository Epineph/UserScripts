#!/usr/bin/env bash

set -Eeuo pipefail

SRC="$HOME/tor-browser/Browser/Downloads"
STAMP="$(date -u +'%Y-%m-%d_%H%M%SZ')"
BASE="zettle_export_${STAMP}"
DEST="$HOME/SecureExports/$BASE"

# 2) Create a destination and move the listed CSVs
mkdir -p "$DEST"
mv "$SRC"/{customers_368896-1_20251001_2115.csv,products_368892-1_20251001_2111.csv,stock_values_368895-1_20251001_2114.csv,translations_368900-1_20251001_2134.csv,users_368901-1_20251001_2134.csv} "$DEST"

# 3) Make a compressed tarball (filenames are concealed once encrypted)
tar --zstd -cvf "$DEST.tar.zst" -C "$(dirname "$DEST")" "$(basename "$DEST")"
