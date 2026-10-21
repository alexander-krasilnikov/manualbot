# Testing

How to run the tests, the tests that need the real models, and the quality evaluations. To try the app without the real
models see [Try it without the real models](using.md#try-it-without-the-real-models).

## Run the tests

```sh
for p in Ports Core Adapters; do (cd Packages/$p && swift test); done      # packages, on the Mac
DEST='platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
xcodebuild test -project ManualBot.xcodeproj -scheme ManualBot -destination "$DEST" \
  -only-testing:ManualBotTests                                                # app unit tests
xcodebuild test-without-building -project ManualBot.xcodeproj -scheme ManualBot -destination "$DEST" \
  -only-testing:ManualBotUITests -parallel-testing-enabled YES -parallel-testing-worker-count 2   # UI tests, ~12 min
```

The UI tests run on two simulator clones at once (about 12 minutes instead of 20). Three clones are not faster: they slow
each other down enough that timing-sensitive tests fail. The unit tests run on their own first for the same reason.

The simulator needs an iOS 27 runtime; the app tests above name `iPad Pro 13-inch (M5)`, which is one.

## Tests against the real models

Tests against the real models are skipped unless you point them at the files (the app downloads its models; to run these
tests fetch them yourself from the `url` entries in `App/Resources/ModelManifest.json`, into a folder outside the
repository or into `LocalModels/`, which git ignores):

| Variable | Points at | Enables |
|---|---|---|
| `EMBEDDER_MODEL_PATH` | `embeddinggemma-2-text-vision-440m.litertlm` | embedder, retrieval and photo evaluations, large-document tests, model validator tests |
| `GENERATOR_MODEL_PATH` | `gemma-4-E2B-it.litertlm` | generator and its warm-up, full-pipeline tests, answer evaluation, model validator tests |
| `ANSWER_EVAL_BASELINE_MODEL_PATH` | `gemma-4-E4B-it.litertlm` | with the two above, runs a baseline model first and prints whether the candidate meets the pass criteria |
| `ANSWER_EVAL_REPORT`, `ANSWER_EVAL_MODEL` | a Markdown file, a name | save the answer evaluation's report and name the model in it |
| `RUN_BENCHMARKS=1` | | 20,000-chunk retrieval benchmark and 5,000-photo search benchmark (add `EMBEDDER_MODEL_PATH`) |
| `RUN_SPIKES=1` | | the EmbeddingGemma 2 spike (output size, input limits, templates, latency), and the minimum-runtime-version spike (add both model paths) |
| `RUN_NETWORK_TESTS=1` | | the model header probe against the real Hugging Face host, and two real manual catalog downloads (a National Laboratory of the Rockies paper and a manufacturer manual) through the app's downloader, checked against the catalog's recorded checksums (`ManualCatalogNetworkTests`) |
| `IMAGE_EVAL_DIR` | a folder of photos (below) | photo and words-to-photo search evaluation on those photos |
| `SYNC_GATEWAY_URL` | `ws://localhost:4984/manualbot`, with the stack in `sync/` running | in `Packages/Adapters`: replication through a real Sync Gateway, including an original of exactly 20 MB and the origin of a catalog document (`SYNC_GATEWAY_PASSWORD` if you changed the accounts' password) |

For the iOS simulator, prefix the variables with `TEST_RUNNER_`.

## Evaluations

```sh
# Retrieval quality (recall, relevance threshold, chunk sizes), in Packages/Adapters:
EMBEDDER_MODEL_PATH=…/embeddinggemma-2-text-vision-440m.litertlm swift test --filter RealEvalTests
# Answer quality of a language model (31 questions and 6 follow-up pairs), comparing a candidate with the current one:
EMBEDDER_MODEL_PATH=… GENERATOR_MODEL_PATH=…/gemma-4-E2B-it.litertlm ANSWER_EVAL_BASELINE_MODEL_PATH=…/gemma-4-E4B-it.litertlm \
  swift test --filter AnswerEvalTests
```

## Photo evaluation

The photo evaluation (`ImageEvalTests`) always runs on a generated set (procedural scenes and drawn shapes such as "a red
circle"), which checks the harness but cannot judge real photos. For real ones, point `IMAGE_EVAL_DIR` at a folder with the
library's photos in `references/`, other photos of the same things (other angle, light, crop) and unrelated photos in
`queries/`, and an `eval.json` that may also list typed descriptions of the reference photos:

```json
{"queries": [{"file": "pump-angle2.jpg", "expected": "pump.jpg"}, {"file": "unrelated.jpg", "expected": null}],
 "texts": [{"text": "a centrifugal pump", "expected": "pump.jpg"}],
 "unrelatedTexts": ["a plate of spaghetti"]}
```

```sh
IMAGE_EVAL_DIR=~/image-eval EMBEDDER_MODEL_PATH=…/embeddinggemma-2-text-vision-440m.litertlm \
  swift test --filter ImageEvalTests    # in Packages/Adapters; prints recall and a threshold table
```

It reports the share of query photos and of descriptions whose expected photo is in the top three, and, for each candidate
threshold, how many matches are kept and how many unrelated photos or descriptions are rejected. Use it to set
`imageMaxDistance` and `textToImageMaxDistance`.

## Reading the log after a crash

Answering a question writes its steps to the system log under the subsystem `com.manualbot.app` (`Diagnostics` in
Ports). The lines are always on, and the system keeps them after the app ends. Questions and answers are never logged,
only their sizes. The categories are:

- `chat`: one line per step of a question, tagged with an ask id (`ask 9C017F70: …`). The steps are started, rewritten,
  retrieved (with relevance and best distance), generating, first text, and generation ended. The last line is the
  outcome: answered, or which of the three not-found cases applied.
- `retrieval`: embedding the query and the searches.
- `generation`: loading the model, then each request queued, running, first piece, and how it ended (end of stream,
  stop sequence, cancelled, runtime error).
- `database`: each vector and keyword query, with the thread it ran on and its time.

After a crash in the Simulator, read the last minutes. The last line before the gap is the step that was running:

```sh
xcrun simctl spawn booted log show --last 10m --style compact \
  --predicate 'subsystem == "com.manualbot.app"'
```

Use plain `log show` with the same predicate for the package tests on the Mac, or Console.app for a connected iPad.
Instruments' Points of Interest shows each generation as a `Generate` interval.

## Documentation screenshots

Most screenshots in `docs/images/` come from a UI test that drives the app with stub models and the seeded library
(`AppUITests/DocsScreenshotsUITests.swift`). It is skipped in the normal test run. To take them again after a UI change:

```sh
scripts/export-doc-screenshots.sh     # light mode, iPad Pro 13-inch (M5); DEVICE='…' for another simulator
```

It switches the simulator to light mode for the run, saves each screen as a test attachment, and copies it to
`docs/images/<name>.png`. Screenshots that need the real models (the hero, the photo answer and the X-ray shots) come
from `scripts/export-doc-screenshots.sh --real`, which downloads the models and runs Reset demo;
[`docs/images/README.md`](images/README.md) lists which is which and how to run it on a simulator of its own.
