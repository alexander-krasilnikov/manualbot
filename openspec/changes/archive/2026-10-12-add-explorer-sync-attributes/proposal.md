# Proposal

## Why

The database explorer shows a document's body but omits the local revision metadata needed to inspect changes and synchronization. Presenters need to see those attributes alongside the JSON and hide them when focusing on the body.

## What Changes

- Add a collapsible **Sync attributes** section above the document JSON, collapsed by default.
- Show locally stored Couchbase Lite document ID, scope, collection, revision ID, sequence, raw revision timestamp, and expiration in highlighted JSON.
- Load attributes automatically on first expansion; retain the result while that document view is open.
- Keep metadata loading and errors within the section, with a retry action after failure and a separate Copy Sync Attributes action.
- Support replicated and device-local collections offline, without adding network requests or X-ray events.
- Limit this change to metadata exposed by the local Couchbase Lite API. Server xattrs, including Sync Gateway's `_sync`, and server inspection endpoints are outside scope.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `database-explorer`: Add hideable local sync attribute inspection above the stored document body.

## Impact

- Extend the `TraceInspector` port and inspector models, the Couchbase inspector adapter, and `FakeTraceInspector`.
- Add document-scoped metadata loading and disclosure state to the explorer's model/view boundary.
- Extend adapter, explorer model, and UI coverage and document the new section in the README.
- Use the existing Couchbase Lite 4.1.2 dependency. No database migration, server changes, or new dependencies are needed.
