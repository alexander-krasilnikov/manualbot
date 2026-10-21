# Spec Delta

## ADDED Requirements

### Requirement: Search stability
Vector search, keyword search and vector index maintenance MUST NOT terminate the app, whichever tasks or threads issued them and whenever those threads end. This holds both during a search and after it, while the app is idle, and it applies equally to searches for a question, for a photo, and during import.

#### Scenario: Idle after a question
- **WHEN** the user asks a question, the answer completes, and the app then stays idle for a minute
- **THEN** the app is still running

#### Scenario: Many searches from short-lived threads
- **WHEN** many vector searches are started from tasks and threads that end as soon as their search returns
- **THEN** every search returns its results and the app keeps running after all of those threads have ended

#### Scenario: Index rebuilt at launch
- **WHEN** the app launches with a library whose vector index has to be created again, for example after the embedding model's dimension changed
- **THEN** the index is rebuilt, and asking a question afterwards neither crashes the app nor makes it end later
