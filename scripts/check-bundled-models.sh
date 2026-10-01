#!/usr/bin/env bash
# Build-phase check: fails the build early, with instructions, if the model that ships inside the app is missing.
# (Downloading and full checksum verification live in fetch-embedder.sh; this only checks presence and size.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/BundledModels/embeddinggemma-300m"
WEIGHTS="$DIR/encoder.mlmodelc/weights/weight.bin"
if [ ! -f "$WEIGHTS" ] || [ "$(stat -f%z "$WEIGHTS")" != "308747648" ] || [ ! -f "$DIR/hf_model/tokenizer.json" ]; then
  echo "error: the bundled EmbeddingGemma model is missing. Run ./scripts/fetch-embedder.sh once, then regenerate the project (xcodegen generate)." >&2
  exit 1
fi
