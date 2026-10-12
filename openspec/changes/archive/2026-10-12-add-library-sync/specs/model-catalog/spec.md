# Spec Delta

## MODIFIED Requirements

### Requirement: Activation confirmation
Activating a model SHALL first ask for confirmation that names its cost. For an embedder, the cost MUST include the number of documents that will be re-indexed, that search uses keywords only for a document until its re-index is done, and that photo search is unavailable until the re-index finishes or, if the embedder cannot embed photos, while it stays active. When sync is on and the embedder is not the fleet model, the cost MUST also say that sync pauses while it is active, naming the fleet model. For a language model, the cost MUST say that an answer being written will stop.

#### Scenario: Activating another embedder
- **WHEN** the user chooses to activate a different embedder with 37 documents in the library
- **THEN** a confirmation says that 37 documents will be re-indexed and photo search is unavailable until that finishes, and nothing changes unless the user confirms

#### Scenario: Leaving the fleet model with sync on
- **WHEN** sync is on and the user chooses to activate an embedder other than the fleet model
- **THEN** the confirmation also says that sync pauses until the fleet model is active again and the library is re-indexed with it

#### Scenario: Cancelling
- **WHEN** the user dismisses the confirmation
- **THEN** the active models, the index and any running work are unchanged
