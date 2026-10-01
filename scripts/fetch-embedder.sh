#!/usr/bin/env bash
# Fetches the EmbeddingGemma Core ML model that ships inside the app into BundledModels/, and verifies it.
#
# Source: https://huggingface.co/valindotai/embeddinggemma-300m-coreml, a Core ML conversion of Google's
# EmbeddingGemma 300M (Gemma Terms of Use: https://ai.google.dev/gemma/terms).
# Files are fetched at a fixed commit and checked against scripts/embedder.sha256, so a changed or
# tampered upstream cannot end up in the app. Weights are not stored in git (BundledModels/ is ignored).
#
# Safe to run repeatedly: files that are already present and correct are kept.
set -euo pipefail

COMMIT="d1dc305086782e958f91fa278de97e4af9caeaf0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/BundledModels/embeddinggemma-300m"
SUMS="$ROOT/scripts/embedder.sha256"
BASE="https://huggingface.co/valindotai/embeddinggemma-300m-coreml/resolve/$COMMIT"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p "$DEST"
fetched=0
while read -r expected path; do
  target="$DEST/$path"
  if [ -f "$target" ] && [ "$(sha "$target")" = "$expected" ]; then continue; fi
  mkdir -p "$(dirname "$target")"
  echo "fetching $path"
  curl -fL --retry 3 --silent --show-error -o "$target.part" "$BASE/$path"
  actual="$(sha "$target.part")"
  if [ "$actual" != "$expected" ]; then
    rm -f "$target.part"
    echo "checksum mismatch for $path (expected $expected, got $actual)" >&2
    exit 1
  fi
  mv "$target.part" "$target"
  fetched=$((fetched + 1))
done < "$SUMS"

echo "EmbeddingGemma ready in ${DEST#$ROOT/} ($fetched file(s) fetched, all checksums verified)"
