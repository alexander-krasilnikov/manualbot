# Proposal

## Why

The README is the first thing shown to people the app is presented to, but it is a 321-line wall of text for four kinds of
reader at once (user, presenter, developer, evaluator), with no screenshots and no picture of how the app works. The ideas
that make the app worth showing (answers only from your documents, all on the iPad, one Couchbase Lite database for
vectors, keywords and photos) are only told, never shown.

## What Changes

- **README becomes a presentation-first front page** (about 80 lines): a one- or two-line pitch, a hero screenshot
  (library, chat with a cited answer, X-ray), three claims each backed by a screenshot, two animated flow diagrams, a short
  quick start, and links to the rest.
- **The rest moves into `docs/`**, grouped by reader, with nothing dropped:
  - `docs/using.md`: Models, Sync, Photos.
  - `docs/demo.md`: X-ray, database explorer, document contents, the eight-step talk track with a screenshot per step,
    and "If asked: so filtered vector search is slow?".
  - `docs/architecture.md`: Ports / Core / Adapters as a Mermaid diagram, the import and ask pipelines, the chunk-ID
    visibility rule, and what syncs versus what stays on the iPad.
  - `docs/testing.md`: test commands, the environment-variable table, evaluations.
  - `sync/README.md` stays where it is and is linked.
- **Screenshots, light mode only**, in `docs/images/`. The hero and X-ray shots are captured once by hand with the real
  models. The rest come from a new UI test that drives the app in stub mode with the seeded library and saves each screen,
  so they can be regenerated when the UI changes.
- **Two looping animated SVGs** in the README (light and dark variants): the ask flow and the import-and-sync flow, using
  the same stage names X-ray shows.
- The out-of-date `openspec/` line in the layout section is corrected.
- **The demo uses real Couchbase documents.** Reset demo imports two bundled Couchbase PDFs, *Couchbase Under the Hood*
  (47 pages) and *Capella Architecture Overview* (21 pages), instead of the generated X200 samples. The talk track, the
  screenshots and the README claims are rewritten around them. The sample-photo button attaches a photo of the Eventing
  debugger screenshot from the whitepaper (page 28), the only technical raster figure in the two PDFs; their
  architecture diagrams are vector drawings, which photo search cannot match. The generated X200 samples stay as test
  fixtures behind `-uiTestSeed`, so the tests, the stub models' scripted answers and the retrieval evaluations keep
  working.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `database-xray`: Reset demo imports the two Couchbase PDFs, so the sample set no longer includes a standalone photo;
  the photo-question scenario no longer assumes a nameplate.

## Impact

- `README.md` rewritten; new `docs/` folder with four Markdown files, `docs/images/` (PNG screenshots and SVG animations).
- `AppUITests/`: one new UI test file that produces screenshots. It is skipped in the normal test run, so the suite time is
  unchanged. The Reset demo UI and unit tests change their expected documents.
- `App/Demo/SampleDocuments.swift` and `App/Resources/`: the two PDFs are bundled (12.5 MB added to the app and the
  repository, which is private; the PDFs are Couchbase material marked "All rights reserved"). A new `-uiTestSeedDemo`
  launch argument seeds them for the documentation screenshots.
- Links into the README from elsewhere (`sync/README.md`, comments that cite README sections, archived OpenSpec changes)
  need checking. Archived changes are left as they are.
- Repository size grows by the images and the two PDFs.
