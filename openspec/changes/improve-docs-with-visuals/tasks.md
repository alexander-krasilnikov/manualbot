# Tasks

## 1. Split the README into docs/

- [x] 1.1 Write the section map (each README heading and table → its target file) in this change's folder as `section-map.md`; verify every `#`/`##`/`###` heading of the current README appears in it exactly once
- [x] 1.2 Create `docs/using.md` from "Set up" (full text), Models, Sync and Photos; verify with a diff that the moved text matches the original apart from heading levels and link targets
- [x] 1.3 Create `docs/demo.md` from "X-ray and the database explorer", Database explorer, Document contents, Talk track and "If asked", with an image placeholder per talk-track step; verify the same way as 1.2
- [x] 1.4 Create `docs/testing.md` from Tests (commands, env-var table, evaluation instructions); verify the same way as 1.2
- [x] 1.5 Replace internal anchors (`#sync`, `#models`, `#photos` and so on) with links to the new files and check `sync/README.md` links; verify by running a Markdown link checker (for example `npx markdown-link-check`) over `README.md` and `docs/*.md` with no broken relative links

## 2. Architecture document

- [x] 2.1 Write `docs/architecture.md`: Mermaid flowchart of App → Core → Ports ← Adapters naming the main adapters, the corrected Layout section (including what `openspec/` now holds), the chunk-ID visibility rule, and what syncs versus stays on the iPad; verify the Mermaid renders in a GitHub preview (or `npx @mermaid-js/mermaid-cli` produces an image without errors)
- [x] 2.2 Add the step-by-step ask and import pipelines, each stage naming the source file that implements it (`ChatService`, `QueryRewriter`, `Retriever`, `RankFusion`, `CitationValidator`, `IngestionService`, `Chunker`); verify each named file and type exists with `grep`

## 3. Animated flow diagrams

- [x] 3.1 Draw `docs/images/ask-flow-light.svg` per design.md (stages lighting up about every 1.2 s with captions, 3 s hold, 10-12 s loop, reduced-motion shows the fully lit diagram, system fonts, no script); verify it animates in Safari and Chrome when opened as an `<img>` and shows the lit still with reduced motion turned on
- [x] 3.2 Make `docs/images/ask-flow-dark.svg` by swapping the color-variable block only; verify with `diff` that only that block differs and that it reads on a dark background
- [x] 3.3 Draw `docs/images/import-sync-flow-light.svg` and `-dark.svg` the same way, including the "to Sync Gateway" and "stays on this iPad" branches; verify as in 3.1 and 3.2
- [x] 3.4 Check every stage label in both diagrams against the X-ray step names and the code paths listed in design.md; verify by listing each label next to the X-ray string or source line it matches in the pull request description
- [ ] 3.5 Embed both animations in `docs/architecture.md` with `<picture>` and full-flow alt text; verify in a GitHub preview in both themes

## 4. Automated screenshots

- [x] 4.1 Add `AppUITests/DocsScreenshotsUITests.swift` (subclass of `UITestCase`, skipped unless `DOCS_SCREENSHOTS=1`, light mode, seeded stub launch) with one method per automated screen from design.md, each saving a `keepAlways` attachment named after its target file; verify the normal UI test run reports the class as skipped and the opt-in run passes on `iPad Pro 13-inch (M5)` when run alone
- [x] 4.2 Add `scripts/export-doc-screenshots.sh` that runs the opt-in test, exports attachments with `xcrun xcresulttool export attachments` and copies them into `docs/images/` by name; verify one run produces every expected PNG
- [x] 4.3 Document the regeneration command in `docs/testing.md`; verify it runs as written

## 5. Hand-made screenshots

- [x] 5.1 With the real models in light mode, capture the hero (library + chat with a cited answer + X-ray on that question), the photo answer and the X-ray talk-track shots (import, vector search, keyword + merge, relevance, photo analysis + image search) with `DocsRealScreenshotsUITests` (`scripts/export-doc-screenshots.sh --real` on a dedicated simulator, downloading the models); verify none shows the stub badge and each talk-track answer matches what `docs/demo.md` says
- [x] 5.2 Write `docs/images/README.md` listing each image, automated or by hand, and how to take the hand-made ones again; verify every file in `docs/images/` is listed
- [x] 5.3 Scale all screenshots to 1024 px wide (and run `oxipng` when installed); verify the total size of `docs/images/` and report it

## 6. Presentation-first README

- [x] 6.1 Rewrite `README.md` (about 80 lines): pitch, hero, three claims each with its screenshot, both animations via `<picture>`, short quick start (`xcodegen generate`, open, stub flags), links to `docs/` and `sync/`; verify it is no more than 100 lines and the first screen on GitHub shows the pitch and hero
- [x] 6.2 Insert the screenshots into `docs/demo.md` (one per talk-track step) and `docs/using.md` (Models, Sync, Photos); verify no placeholder is left (`grep -n "TODO\|placeholder" docs/*.md` is empty)

## 7. Integration check

- [x] 7.1 Check content survival: every heading and table in `section-map.md` is present exactly once in the new files, and the link checker passes over all Markdown; verify by ticking off `section-map.md`
- [ ] 7.2 Read the README on a GitHub preview of the branch in light and dark themes on a laptop-width window and a phone-width window; verify the animations play, the images load and nothing scrolls sideways

## 8. Couchbase demo samples

- [x] 8.1 Copy the two PDFs into `App/Resources/DemoSamples/`, remove the three X200 text files there, and make `SampleDocuments.write` return the two PDFs; verify by updating `SampleDocumentsTests` (names, identities, both extract with text, *Under the Hood* has an image on page 28) and running them
- [x] 8.2 Add `scripts/make-sample-photo.swift` and generate `App/Resources/sample-photo.jpg` from page 28; point the chat's sample-photo button at it with the label "Use the sample photo"; verify the image by looking at it and with a unit test that the photo decodes and Vision reads text off it
- [x] 8.3 Add `-uiTestSeedDemo` (stub seed of the two PDFs) and `-uiTestPhoto sample`; update the Reset demo UI tests to expect the two PDFs and the sample photo to find *Couchbase Under the Hood*, page 28; verify by running `DemoUITests` alone
- [x] 8.4 Switch `DocsScreenshotsUITests` to `-uiTestSeedDemo` (and `-uiTestPhoto sample` for the photo answer), re-run `scripts/export-doc-screenshots.sh`; verify each PNG shows the Couchbase documents
- [x] 8.5 Rewrite the talk track (`docs/demo.md`), the README claims and `docs/images/README.md` around the Couchbase documents and the sample photo, and update the Reset demo text in `docs/demo.md`; verify with the link checker and by grepping for leftover X200 references in `README.md` and `docs/`
- [x] 8.6 Run the app-target unit tests and the UI tests that touch samples (`DemoUITests`, `PhotoDemoUITests`, `ContentsUITests`, `ExplorerUITests`); verify they pass

## Workflow follow-up

- Archive the change after review; `skip_specs` is set, so there are no specs to sync.

Notes: 3.1 and 3.3 were checked in Chrome only; the Safari check was waived. 5.3: screenshots are 1024 px wide; `docs/images/` totals 3.4 MB (14 screenshots and 4 SVGs), above the 3 MB first planned.
