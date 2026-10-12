# Section map

Every heading and table of the README before this change, and where it lives afterwards. Ticked in task 7.1.

| Old README (line) | Content | New home |
|---|---|---|
| `# ManualBot` (1) | pitch and the bullet list (search, photos, answers, runtime, offline, targets) | `README.md`: pitch and claims; full bullet list in `docs/architecture.md` → "What it is made of" |
| `## Set up` (23) | requirements, `xcodegen` commands | `README.md` → "Run it" (short); full text in `docs/using.md` → "Set up" |
| `## Set up` (32-44) | first-launch downloads, old-model clean-up, re-index after an embedder update, simulator CPU | `docs/using.md` → "Set up" |
| `### Try it without the real models` (46) | stub launch arguments and scenarios | `docs/using.md` → "Try it without the real models"; one-line version in `README.md` |
| `## Models` (56) | Models page | `docs/using.md` → "Models" |
| `## Sync` (105) | sync | `docs/using.md` → "Sync" |
| `## Photos` (135) | photos | `docs/using.md` → "Photos" |
| `## X-ray and the database explorer` (167) | X-ray panel | `docs/demo.md` → "X-ray" |
| `### Database explorer` (186) | explorer, sync attributes | `docs/demo.md` → "Database explorer" |
| `### Document contents` (203) | chunk and image view | `docs/demo.md` → "Document contents" |
| `### Talk track` (216) | eight demo steps | `docs/demo.md` → "Talk track" |
| `### If asked: "so filtered vector search is slow?"` (242) | visibility filter numbers | `docs/demo.md` → "If asked"; the rule itself also explained in `docs/architecture.md` |
| `## Tests` (251) | test commands, parallel note | `docs/testing.md` → "Run the tests" |
| table (269) | environment variables | `docs/testing.md` → "Tests against the real models" |
| code block (283-289) | retrieval and answer evaluations | `docs/testing.md` → "Evaluations" |
| photo evaluation text, `eval.json`, command (291-311) | photo evaluation | `docs/testing.md` → "Photo evaluation" |
| `## Layout` (313) | folder layout | `docs/architecture.md` → "Where the code is" (with the `openspec/` line corrected) |

Checked in task 7.1: every old README line is present in `README.md` or `docs/`, except lines deliberately rewritten — the
pitch (now the README's opening and claims), links retargeted to the new files and the archived evaluation path, the
Reset demo sample description and the talk track (now about the Couchbase PDFs), and the corrected Layout lines.
