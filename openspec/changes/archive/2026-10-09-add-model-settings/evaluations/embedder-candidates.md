# Embedder candidates: evaluation results

Run on 2026-10-09 on the Mac (GPU), with the evaluations that settle the shipped embedder: `RealEvalTests` (retrieval, 25 answerable and
6 off-topic questions over the evaluation documents) and `ImageEvalTests` on the stand-in photo set (14 photos, 28 word queries, 6
unrelated photos). Each model file was verified against the SHA-256 Hugging Face reports before it was used.

| Model | File | Size | Images |
|---|---|---|---|
| EmbeddingGemma 2 Text Vision 440M (shipped, baseline) | `embeddinggemma-2-text-vision-440m.litertlm` | 388 MB | yes |
| EmbeddingGemma 2 Text 270M | `embeddinggemma-2-text-270m.litertlm` | 165 MB | no |
| EmbeddingGemma 2 740M | `embeddinggemma-2-740m.litertlm` | 485 MB | yes (and audio and video, which the app does not use) |

The main model card (`google/embeddinggemma-2`) says the three files are one model with different encoders loaded: a 270M text
backbone, plus a vision encoder (440M), plus an audio encoder (740M), in one 768-dimension space that truncates to 128, 256, 512
or 768. The measurements agree.

## Prompts

Two prompt sets were run on every model:

- **current**: what the app ships for the 440M (`task: search query | text: …` for questions, `task: search result | title: … | text: …`
  for passages), chosen by the earlier spike.
- **card**: what the main model card documents for document search (`task: search result | query: …` for questions,
  `title: … | text: …` for passages, `title: none | text: …` without a title).

## Retrieval (pass: recall@6 at least 85%, and one threshold that lets every answerable question through and refuses every off-topic one)

| Model | Prompts | recall@6 | answerable max | off-topic min | gap | thresholds that separate perfectly | 0.28 |
|---|---|---|---|---|---|---|---|
| 440M | current | 100% (25/25) | 0.239 | 0.323 | 0.083 | 0.240 to 0.320 | 100% / 100% |
| 440M | card | 100% (25/25) | 0.260 | 0.369 | 0.108 | 0.265 to 0.365 | 100% / 100% |
| 270M | current | 100% (25/25) | 0.239 | 0.323 | 0.083 | 0.240 to 0.320 | 100% / 100% |
| 270M | card | 100% (25/25) | 0.260 | 0.369 | 0.108 | 0.265 to 0.365 | 100% / 100% |
| 740M | current | 100% (25/25) | 0.239 | 0.323 | 0.083 | 0.240 to 0.320 | 100% / 100% |
| 740M | card | 100% (25/25) | 0.260 | 0.369 | 0.108 | 0.265 to 0.365 | 100% / 100% |

All three models give the same figures to three decimals, as one text backbone should. **Both candidates pass.** They keep the
shipped prompts and the shipped threshold (0.28, inside the perfect range for both prompt sets).

An observation, not acted on: the card's prompts leave a wider gap (0.108 against 0.083) on all three models. That would also
apply to the shipped 440M and is a separate change; the earlier spike chose the current prompts and nothing here contradicts them.

## Photos (only models with images; pass: photo top-3 recall at least 80%, words-to-photo top-3 recall at least 70%)

| Model | photo to photo, top-3 | words to photo, top-3 | photo matches kept / unrelated rejected at 0.25 | word matches kept / unrelated rejected at 0.30 | Result |
|---|---|---|---|---|---|
| 440M (baseline) | 0.86 (12 of 14) | 1.00 (28 of 28) | 0.71 / 0.83 | 1.00 / 1.00 | pass |
| 740M | 0.86 (12 of 14) | 1.00 (28 of 28) | 0.71 / 0.83 | 1.00 / 1.00 | pass |

The 270M has no images, so it is judged on text retrieval alone and its profile has `supportsImages = false`.

## Result

| Candidate | Text retrieval | Photos | Result |
|---|---|---|---|
| 270M | pass | not applicable (text only) | **pass** |
| 740M | pass | pass | **pass** |

Both go into the catalog with the shipped prompts, chunk sizes and distances.

## Found on the way

`LiteRTEmbedder` always asked the engine for a vision encoder, so any text-only model failed to load
(`tf_lite_vision_encoder not found in the model`). It now asks only when the profile has images. The 270M loads and embeds with a
test on the real file (`TEXT_ONLY_EMBEDDER_MODEL_PATH`).

## Reproducing

```sh
# in Packages/Adapters; profiles are JSON files in the shape of EmbedderProfile
EMBEDDER_MODEL_PATH=…/embeddinggemma-2-740m.litertlm EMBEDDER_PROFILE_PATH=…/profile.json \
  swift test --filter RealEvalTests/retrievalMeetsTheQualityTargets
EMBEDDER_MODEL_PATH=… EMBEDDER_PROFILE_PATH=… IMAGE_EVAL_DIR=…/image-eval \
  swift test --filter ImageEvalTests/realPhotosAreFoundAndUnrelatedOnesAreRejected
```
