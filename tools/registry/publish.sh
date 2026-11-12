#!/usr/bin/env bash
# Publishes every pack in a directory to the R2 bucket, and checks each one first.
#
# The manifest is the contract: its `size_bytes` and `sha256` must describe the
# archive that this script uploads. A mismatch stops the upload, because a
# broken registry answer is worse than no upload.
#
#   BUCKET=read-later-dev tools/registry/publish.sh <pack-dir>
#
# The pack directory holds `*.pack.gz` files and their `*.manifest.json` files.
# Only the manifest's own `id` selects its archive, so the gloss pack and the
# lexical pack can sit in the same folder.
set -euo pipefail

BUCKET="${BUCKET:-read-later-dev}"
PACK_DIR="${1:-}"

if [[ -z "$PACK_DIR" || ! -d "$PACK_DIR" ]]; then
  echo "usage: BUCKET=read-later-dev $0 <pack-dir>" >&2
  exit 2
fi

shopt -s nullglob
manifests=("$PACK_DIR"/*.manifest.json)
shopt -u nullglob

if [[ ${#manifests[@]} -eq 0 ]]; then
  echo "no *.manifest.json in $PACK_DIR" >&2
  exit 2
fi

wrangler_bin="${WRANGLER:-wrangler}"
published=0

for manifest in "${manifests[@]}"; do
  field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$manifest" "$1"
  }

  id="$(field id)"
  version="$(field version)"
  want_size="$(field size_bytes)"
  want_sha="$(field sha256)"

  archive="$PACK_DIR/$id.pack.gz"
  if [[ ! -f "$archive" ]]; then
    echo "no archive for $id: expected $archive" >&2
    exit 1
  fi

  got_size="$(wc -c < "$archive" | tr -d ' ')"
  got_sha="$(shasum -a 256 "$archive" | cut -d' ' -f1)"

  if [[ "$got_size" != "$want_size" ]]; then
    echo "$id: size mismatch: manifest $want_size, file $got_size" >&2
    exit 1
  fi
  if [[ "$got_sha" != "$want_sha" ]]; then
    echo "$id: sha256 mismatch: manifest $want_sha, file $got_sha" >&2
    exit 1
  fi

  # A published version never changes. An existing object under the same
  # version path is either the same bytes or a mistake, and R2 will not tell
  # us which. Refuse the second case here by naming it.
  archive_key="packs/$id/$version/$(basename "$archive")"
  manifest_key="packs/$id/manifest.json"

  echo "bucket   $BUCKET"
  echo "pack     $id $version"
  echo "archive  $archive_key ($got_size bytes)"
  echo "manifest $manifest_key"

  "$wrangler_bin" r2 object put "$BUCKET/$archive_key" \
    --file "$archive" \
    --content-type application/gzip \
    --remote

  "$wrangler_bin" r2 object put "$BUCKET/$manifest_key" \
    --file "$manifest" \
    --content-type application/json \
    --cache-control "public, max-age=300" \
    --remote

  published=$((published + 1))
  echo
done

echo "published $published pack(s) to $BUCKET"
echo "next: fetch the manifest and one archive from the public URL, and compare."
