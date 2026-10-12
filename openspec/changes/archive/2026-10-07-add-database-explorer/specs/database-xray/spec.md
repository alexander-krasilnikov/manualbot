# Spec Delta

## ADDED Requirements

### Requirement: Always available
The app SHALL always show the Source / X-ray switch in the detail column and the database explorer control in the workspace, with no setting or launch argument needed, and tracing MUST record operations from launch. Tracing MUST NOT change what is retrieved, answered, imported or stored.

#### Scenario: Fresh install
- **WHEN** the app is launched for the first time
- **THEN** the detail column shows a Source / X-ray switch, the workspace shows the Database control, and the X-ray log lists the operations since launch

#### Scenario: Same answers with tracing on or off
- **WHEN** the same question is asked over the same library with tracing disabled and with it enabled
- **THEN** the retrieved passages, answer and citations are the same

## MODIFIED Requirements

### Requirement: Detail column switch
The detail column SHALL switch between the source viewer and the X-ray panel. Tapping a citation or a library document MUST switch the column to Source and open it as before. Switching to X-ray MUST NOT close the open source.

#### Scenario: Citation tap while X-ray is showing
- **WHEN** X-ray is showing and the presenter taps a citation
- **THEN** the column switches to Source and shows the cited passage highlighted

#### Scenario: Return to X-ray
- **WHEN** the presenter switches from Source to X-ray and back
- **THEN** the same source is still open at the same position

### Requirement: Live operation log
The X-ray panel SHALL show events as they happen, grouped by the user operation that caused them: importing a document, asking a question, opening a source, re-indexing, deleting a document, and resetting the demo. Each group MUST show its title, start time and total duration, and each event its time and duration where measurable. Database activity not caused by a user operation (for example, refreshing the library list) MUST be grouped as background activity, hidden by default and shown on request. The most recent group MUST be expanded and earlier groups collapsed. The log MUST keep at least the last 50 groups. The presenter MUST be able to clear the log.

#### Scenario: Events appear while answering
- **WHEN** the presenter asks a question with X-ray showing
- **THEN** a new group titled with the question appears, expanded, and its events appear as each step completes

#### Scenario: Background activity hidden
- **WHEN** the library refreshes its list without a user action
- **THEN** no new visible group appears unless background activity is shown

#### Scenario: Clear
- **WHEN** the presenter clears the log
- **THEN** the panel is empty and new operations start appearing again

### Requirement: Document inspection
Tapping a passage or document ID in an event SHALL open the database explorer at that stored document, showing its field names and values as stored. Vector fields MUST be shortened as for parameters; blob fields MUST show their content type, size and digest, not their content. If the document no longer exists, the explorer MUST say so. Closing the explorer MUST return to the X-ray panel with the log as it was.

#### Scenario: Inspect a passage
- **WHEN** the presenter taps a passage ID in a fusion event
- **THEN** the explorer opens at that passage's stored document, including its text, page, generation, embedding model and a shortened embedding

#### Scenario: Deleted since
- **WHEN** the presenter taps the ID of a passage whose document was deleted
- **THEN** the explorer says the document no longer exists

#### Scenario: Back to X-ray
- **WHEN** the presenter closes the explorer opened from an X-ray event
- **THEN** the X-ray panel is showing, with the same groups expanded as before

### Requirement: Reset demo
The X-ray panel SHALL offer a reset action that, after a confirmation naming what will be deleted, deletes every document and chat and imports a fixed set of bundled sample documents, including at least one PDF, one photo, and one document that contains a photo. The reset MUST be traced as its own operation. Cancelling the confirmation MUST change nothing.

#### Scenario: Reset
- **WHEN** the presenter confirms reset
- **THEN** the library contains only the sample documents, which become ready, the chat list is empty, and the X-ray log shows the deletions and the imports

#### Scenario: Cancel reset
- **WHEN** the presenter cancels the reset confirmation
- **THEN** the library and chats are unchanged

## REMOVED Requirements

### Requirement: Demo mode
**Reason**: X-ray and the explorer are now part of the app at all times, so there is nothing to switch on. A remembered setting or launch argument would only hide features from the people who want them.
**Migration**: None needed. The stored `xray.demoMode` preference and the `-demoMode` launch argument are ignored.
