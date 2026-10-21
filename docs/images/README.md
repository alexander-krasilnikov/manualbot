# Images

Every image used by the README and `docs/`, and how to make it again. Screenshots are light mode, iPad Pro 13-inch (M5)
simulator, landscape.

## Automated

Taken by `scripts/export-doc-screenshots.sh` (stub models, the two sample PDFs seeded with `-uiTestSeedDemo`; see [Testing](../testing.md#documentation-screenshots)).
Re-run it after a UI change; it overwrites these files.

| File | Screen | Used in |
|---|---|---|
| `library.png` | library with *Couchbase Under the Hood* open in the source column | `using.md` |
| `contents-chunk.png` | contents of *Couchbase Under the Hood*, chunk 4 selected | `demo.md` |
| `contents-image.png` | contents of *Couchbase Under the Hood*, the debugger figure on page 28 selected | `demo.md` (talk track 7) |
| `explorer-document.png` | database explorer, a document with its sync attributes expanded | `demo.md` |
| `explorer-query.png` | database explorer, the keyword-search starter run in the SQL++ console | `README.md`, `demo.md` (talk track 6) |
| `manual-catalog.png` | the manual catalog on the Couchbase category, a bundled sample whitepaper shown as "In library" | `using.md` |
| `models.png` | Settings → Models | `using.md` |
| `sync.png` | Settings → Sync, up to date (stand-in replicator) | `using.md` |

## With the real models

These show answers, photo matches and X-ray distances, which only mean something with the real models (X-ray would also
show the "Stub models" badge in stub mode). `scripts/export-doc-screenshots.sh --real` takes them
(`DocsRealScreenshotsUITests`): it starts the app as a user would, downloads the models if needed, runs Reset demo and asks
the talk track's questions, so run it on a simulator whose library may be deleted, for example a dedicated one:

```sh
xcrun simctl create "ManualBot Docs" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
DEVICE='ManualBot Docs' scripts/export-doc-screenshots.sh --real
```

Talk-track step 8 (airplane mode) has no screenshot: a simulator cannot go offline on its own.

| File | What to show | Used in |
|---|---|---|
| `hero.png` | "What is a vBucket?" answered with citations, the source column switched to X-ray on that question | `README.md` |
| `photo-answer.png` | the sample photo sent alone, answered with page 28 of *Couchbase Under the Hood* and its figure | `README.md`, `using.md` |
| `talk-1-import.png` | X-ray right after Reset demo, an Import group expanded (blob stored, chunks written, chunk set made searchable) | `demo.md` |
| `talk-2-ask.png` | X-ray for "What is a vBucket?", the vector search step expanded | `demo.md` |
| `talk-3-exact-codes.png` | X-ray for "What is port 11207 used for?", keyword search and the merge expanded | `demo.md` |
| `talk-4-follow-up.png` | an off-topic question answered "I couldn't find an answer…", X-ray showing the relevance check and "Language model not called" | `README.md`, `demo.md` |
| `talk-5-photo.png` | the sample photo sent alone, X-ray showing the photo analysis and the image search | `demo.md` |

`App/Resources/sample-photo.jpg`, the sample photo itself, is made from page 28 of the bundled whitepaper by
`swift scripts/make-sample-photo.swift`.

## App icon

`app-icon.png` is the app icon as the home screen shows it (masked, for use in docs). The icon itself is
`App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`, one 1024 px image without transparency, which iPadOS
scales for every size.

## Diagrams

`ask-flow-light.svg`, `ask-flow-dark.svg`, `import-sync-flow-light.svg` and `import-sync-flow-dark.svg` are hand-editable
SVG with CSS animation. The light and dark files differ only in the color block at the top of the `<style>`: change the
layout in the light file, copy it over the dark one and put the dark colors back. Stage names follow the X-ray step names.
