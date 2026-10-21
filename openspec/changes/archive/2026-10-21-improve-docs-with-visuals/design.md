# Design

## Context

See proposal.md for why. Current state that shapes the approach:

- `README.md` (321 lines) is the only top-level document. `sync/README.md` and `Packages/LiteRTLMKit/README.md` are
  separate and linked. No source file links to a section of the root README, so moving sections does not break code
  comments. `sync/docker-compose.yml` says "See README.md", which means its own folder's README.
- The UI tests already have a deterministic mode: `UITestCase.launch(_:extra:)` in `AppUITests/AppUITests.swift`
  starts the app with `-uiTestModelStub <scenario>`. With `-uiTestSeed` it imports five sample documents.
  `-uiTestSync upToDate` and `-uiTestSearch results` fill the Sync and Models pages. Tests run in landscape.
- In stub mode the X-ray status bar shows "Stub models: distances are not real" (`xrayStubBadge`,
  `App/Demo/XrayPanelView.swift`). Stub answers are scripted text.
- The real ask path, in `ChatService` and `Retriever`: rewrite a follow-up into a standalone query → embed it → vector
  search, keyword search and words-to-photo search in parallel (plus photo-to-photo when a photo is attached) →
  rank fusion → relevance check (nothing relevant means an instant "the documents don't say", with no model call) →
  generate from the retrieved chunks → citation check (`CitationValidator`) keeps only citations of retrieved chunks.
- The repository is on GitHub, and the README is read there.

## Goals / Non-Goals

**Goals:**
- Every fact in today's README survives, in exactly one place.
- Screenshots can be regenerated with one command, except for the few captured by hand on purpose.
- The animations match the code: no stage the code does not have, and no stage left out that X-ray shows.

**Non-Goals:**
- Dark-mode screenshots, localized docs, a documentation website or GitHub Pages.
- Interactive or step-through animations for use on a projector.
- Changing app behavior or UI to make screenshots look better (for example, hiding the stub badge).
- Rewriting `sync/README.md` or `Packages/LiteRTLMKit/README.md`.

## Decisions

### 1. Split by reader, README as the front page

```
README.md         pitch, hero, 3 claims + shots, 2 animations, quick start, links
docs/using.md     Models, Sync, Photos                     (from README 56-165)
docs/demo.md      X-ray, explorer, contents, talk track,   (from README 167-249)
                  "If asked"
docs/architecture.md  Mermaid Ports/Core/Adapters, pipelines, visibility rule,
                      what syncs                           (new, plus Layout 313-321)
docs/testing.md   tests, env-var table, evals              (from README 251-311)
```

"Set up" stays in the README, shortened to the two commands and the stub flags, with the full text (model downloads,
re-index after an embedder update, simulator CPU note) in `docs/using.md`. Anchors that sections link to inside the README
(`#sync`, `#models`) become links to the new files.

*Alternative considered:* one README with a table of contents and collapsible `<details>` sections. Rejected: the first
screen would still be text, and collapsed blocks hide the content from search on the page.

### 2. Screenshots: a skipped-by-default UI test, plus a few captured by hand

A new `AppUITests/DocsScreenshotsUITests.swift` subclasses `UITestCase`. Each test method reaches one screen and saves
`XCUIScreen.main.screenshot()` as an `XCTAttachment` named after the target file (for example `library.png`), with
`lifetime = .keepAlways`. The class is skipped unless `DOCS_SCREENSHOTS=1` (`TEST_RUNNER_DOCS_SCREENSHOTS=1` from
`xcodebuild`), so the normal suite runs no longer. Light mode is set on the simulator by the export script
(`xcrun simctl ui <device> appearance light`, restored afterwards).

(Changed during implementation: a `-AppleInterfaceStyle` launch argument is not reliable on iOS, so the appearance is set
on the simulator. `app.screenshot()` in landscape produced a rotated, cropped image, so the test draws the full-screen
image upright before attaching it. The script scales each PNG to 1024 px wide, about 250 KB, and runs `oxipng` when it
is installed.)

Regeneration (written into `docs/testing.md`):

```sh
TEST_RUNNER_DOCS_SCREENSHOTS=1 xcodebuild test -project ManualBot.xcodeproj -scheme ManualBot \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:ManualBotUITests/DocsScreenshotsUITests -resultBundlePath /tmp/shots.xcresult
xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots
# copy the PNGs into docs/images/ by attachment name (the export writes a manifest.json that maps names to files)
```

A short script, `scripts/export-doc-screenshots.sh`, does the export and the copy so that this is one command.

Automated (stub mode, seeded): library, document contents (chunk and image), database explorer (collection list,
document with sync attributes, query console), Models page, Sync settings, chat with a photo answer. None of them show
the X-ray panel, so the stub badge never appears.

With the real models, light mode: the hero (library + chat with a cited answer + X-ray open on that question), the
photo answer and the X-ray shots for the talk track. (Changed during implementation: instead of by hand, a second
opt-in class, `DocsRealScreenshotsUITests` behind `DOCS_SCREENSHOTS_REAL=1`, launches the app without stubs, downloads
the models if needed, runs Reset demo and walks the talk track, clearing X-ray before each question. It runs with
`-sync.enabled NO` and is meant for a dedicated simulator, because Reset demo deletes the library. Airplane mode cannot
be scripted on a simulator, so talk-track step 8 has no screenshot.) `docs/images/README.md` lists every image, whether it is automated or by hand, and how to take the
hand-made ones again.

*Alternatives considered:* everything by hand (goes stale silently); everything automated (the hero would show a
scripted answer and the stub badge, which undercuts the "real, on-device" claim); a launch flag that hides the badge
(changes the app for the sake of docs).

### 3. Animations: hand-written SVG with CSS keyframes, two theme files each

Four files: `docs/images/ask-flow-light.svg`, `ask-flow-dark.svg`, `import-sync-flow-light.svg`,
`import-sync-flow-dark.svg`. They are embedded with:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/ask-flow-dark.svg">
  <img src="docs/images/ask-flow-light.svg" alt="(the whole flow in words)">
</picture>
```

- GitHub shows SVG through `<img>`, which runs CSS animation but no script and no external fonts, so the files use
  only `@keyframes`, inline `<style>` and a system font stack.
- The light and dark files share one layout. Only a block of color variables at the top differs, so the dark file is
  made by copying the light one and swapping that block. A color-scheme media query inside one SVG would follow the
  operating system instead of the GitHub theme, so it is not used.
- Timing: one stage lights up about every 1.2 s with a caption line under the diagram, then the full diagram holds for
  about 3 s and the loop restarts. That is 10-12 s in total, set by `animation-delay` on each stage with a shared
  duration.
- `@media (prefers-reduced-motion: reduce)` turns the animation off and shows every stage lit. That is also what a
  viewer that does not animate shows.
- The `alt` text describes the whole flow in one or two sentences, so the flow is understood without the image.

Ask flow (stage labels as X-ray shows them):

```
question --> rewrite follow-up --> embed question
   --> [ vector search chunks_vec | keyword search chunks_fts | words-to-photo images_vec ]
   --> rank merge --> relevance check --x--> "The documents don't say" (no model call)
                          |
                          v
       Gemma 4 E2B answers from the retrieved chunks --> citation check --> answer + page citations
   frame: "on the iPad · one Couchbase Lite database · works offline"
```

The photo-to-photo search of an attached photo is shown as a fourth list that fades in at the merge with the caption
"with a photo", rather than as a separate flow.

Import and sync flow:

```
file --> store original as a blob beside its JSON record + queue an indexing job (ingestJobs)
   --> extract text (Vision reads scans and photos) --> chunk
   --> read photos, write them in one transaction
   --> embed + write chunks with their vectors, one transaction per batch
   --> make chunk set N searchable (one switch)
          |
          +==> Sync Gateway: documents, chunks, images
          x    stays on this iPad: chats, messages, ingestJobs, vector and keyword indexes
```

(Corrected during implementation: the first draft showed the original, chunks and vectors written in one transaction.
`IngestionService` stores the original when the document is queued, and writes chunks in batches of 16, each batch in
its own transaction. This matches the talk track and the X-ray step names.)

*Alternatives considered:* GIF or MP4 recorded from HTML (large, blurry, binary diffs, MP4 cannot be embedded from the
repository); Mermaid (shown on GitHub but not animated; used for the static diagram in `docs/architecture.md`); an SVG
generated by a script (more machinery than two hand-written diagrams need).

### 4. `docs/architecture.md` uses Mermaid for structure

A `flowchart` of App → Core → Ports ← Adapters, with the main adapters named (Couchbase Lite, LiteRT-LM, Vision,
extractors, downloader, replicator). GitHub renders it, and it is text, so it changes with the code in the same pull
request. The two animated SVGs are embedded again here, followed by the written step-by-step description.

### 5. Demo samples: two bundled Couchbase PDFs, X200 set kept as fixtures

- `App/Resources/DemoSamples/` holds `Couchbase Under the Hood.pdf` (47 pages, 7.1 MB) and
  `Capella Architecture Overview.pdf` (21 pages, 5.4 MB). `SampleDocuments.write` returns these two, so Reset demo imports
  them; their identities follow the existing rule (`sample-couchbase-under-the-hood`,
  `sample-capella-architecture-overview`), so samples loaded on several syncing iPads stay one document each. The three
  bundled X200 text files are only used by Reset demo and are removed. The code that generates the X200 PDF and
  nameplates stays: the stub seed (`-uiTestSeed`), its scripted answers and many tests are built on it.
- **Sample photo.** The diagrams in both PDFs are vector drawings, not images, so the app never stores them as photos.
  The raster images are stock photos, covers, icons, and one technical figure: the Eventing debugger screenshot on page
  28 of *Under the Hood*. `App/Resources/sample-photo.jpg` is that figure as if photographed: page 28 rendered at a
  different scale, cropped with a margin of the page around the figure, turned by about 2° and slightly warmed.
  `scripts/make-sample-photo.swift` makes it from the bundled PDF, so it can be made again. The chat's sample-photo
  button attaches it (its label becomes "Use the sample photo").
- **Stub mode.** `-uiTestSeedDemo` seeds the two PDFs instead of the fixtures, for the documentation screenshots, and
  `-uiTestPhoto sample` makes the stub's attach button attach the sample photo instead of the X200 nameplate. The stub's
  8 × 8 colour features cannot match this photo to the figure (decoded as the app decodes photos, its edges come out
  darker, and the mostly white figure has little else to go by), so in stub mode the photo question runs but finds
  nothing; that the photo finds page 28 first is a unit test with the real model (`SamplePhotoMatchTests`, distance
  0.04, with three stock photos next at about 0.21). The photo-answer screenshot is therefore taken by hand.
- **Talk track and README** are rewritten around these documents (for example "What is a vBucket?", the exact token
  "11207" for the keyword search, "What is XDCR?" then "Can it replicate only some collections?" for the follow-up).
  Every question and the answer it gets were checked with the real models by the screenshot run; "How does it resolve
  conflicts?" was rewritten correctly but not answered, so the talk track does not use it.

*Alternatives considered:* replacing the X200 set everywhere (every stub script, evaluation set and about 40 test files
would have to be rewritten, and the evaluations re-baselined); rasterizing the PDFs' vector diagrams during import so
they become searchable photos (an app feature of its own, out of scope); keeping the nameplate demo alongside (the demo
would mix real documents with generated ones).

## Risks / Trade-offs

- [Facts are lost or duplicated in the split] → Map each README section to its target before moving anything (task 1),
  and check that every heading and table of the old README exists exactly once afterwards.
- [Hand-made screenshots go stale] → `docs/images/README.md` records which images are by hand and how to take them; the
  automated set covers the screens that change most.
- [GitHub stops animating SVG, or a viewer does not] → The reduced-motion state is the full, lit diagram, so a static
  render still reads correctly; the alt text carries the flow.
- [The animation drifts from the code] → Stage labels reuse the X-ray step names, and `docs/architecture.md` names the
  source files that implement each stage, so a pipeline change shows where the docs must change.
- [Large images bloat the repository] → Crop screenshots to the relevant column where possible and run them through
  lossless PNG optimization; aim for under 3 MB in total.
- [Stock photos in the PDFs are stored as photos too, so a words → photos search such as "a debugger" may also show a
  photo of a person at a screen] → Check the debugger figure ranks first with the real models; if not, phrase the
  talk-track question so it does.
- [12.5 MB of PDFs in the app and the repository] → Accepted for a demo app; the repository is private.
- [The screenshot test is flaky on simulators] → It is opt-in and never part of the regular suite; run it alone, not in
  parallel.

## Migration Plan

Docs only. Land in one pull request; rollback is reverting it. Old links to README anchors (`README.md#sync` and so on)
from outside the repository fall back to the top of the README, which links to every new file.
