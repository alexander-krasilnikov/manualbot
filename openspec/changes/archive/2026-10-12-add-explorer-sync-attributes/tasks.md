# Tasks

## 1. Local metadata inspection

- [x] 1.1 Add the Sendable `DocumentSyncAttributes` value and optional, throwing `TraceInspector.syncAttributes(collection:id:)` read in Ports; update `FakeTraceInspector` and other conformers. Verify Ports tests pass and fake reads distinguish configured metadata, missing records, and read errors.
- [x] 1.2 Implement the local read in `CouchbaseTraceInspector.swift` using public document properties and collection expiration APIs. Extend `CouchbaseInspectorTests` to verify saved revision fields, exact integer values, unset/set expiration, replicated and local-only collections, and a missing document; verify inspection does not change the document, collection count, or trace.

## 2. Document attribute state and formatting

- [x] 2.1 Add document-scoped attribute loading through the explorer with idle/loading/loaded/missing/failed states, automatic first-expansion loading, successful-result retention, Retry, and rejection of stale completions. Extend `AppTests/ExplorerTests.swift` with delayed/erroring fake reads; verify collapse/re-expansion avoids another read and navigation cannot mix document results.
- [x] 2.2 Serialize the seven metadata keys as pretty-printed JSON, preserving UInt64 values, explicit nulls, and UTC expiration strings, and reuse `JSONHighlighter`. Add focused formatting coverage that verifies display and copy JSON preserve integers above 2^53 and UInt64.max and that body copying remains separate.

## 3. Hideable section and documentation

- [x] 3.1 Add the initially collapsed Sync attributes disclosure before the document JSON in `ExplorerDocumentView.swift`, with inline progress/error/missing states, Retry, Copy Sync Attributes, and accessibility identifiers. Extend `AppUITests/ExplorerUITests.swift` to verify placement, expansion/collapse, copy actions, and continued reference, vector, and blob interaction.
- [x] 3.2 Update the README's database explorer documentation to explain automatic local loading, hiding the section, the available fields, and snapshot behavior. Verify it describes local revision metadata without implying server xattrs or upload status, and matches the implemented UI labels.

## 4. Integration verification

- [x] 4.1 Run the affected Ports, adapter inspector, explorer model, and explorer UI suites using the repository's documented test commands; verify the app builds with all inspector conformers updated and existing explorer checks still pass.
- [x] 4.2 Validate inspection with sync disabled and offline: open replicated and local-only records, expand/collapse attributes, and navigate between them. Verify the JSON remains usable, no network work is initiated, and the X-ray log and stored documents remain unchanged.
