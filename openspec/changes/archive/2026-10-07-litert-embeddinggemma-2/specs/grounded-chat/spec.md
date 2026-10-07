# Spec Delta

## ADDED Requirements

### Requirement: Answer quality baseline
The project SHALL maintain an answer evaluation over the retrieval evaluation set, run with the installed language model on the real retrieval stack. For answerable questions it MUST report how often the answer states the expected fact, how often it cites a passage that contains it, and how often it is wrongly refused; for unanswerable questions, how often an answer is generated at all; and the time to first text and generation speed. A language model MUST NOT replace the current one unless it meets pass criteria recorded in the project before the evaluation of the candidate is run.

#### Scenario: Comparing language models
- **WHEN** the answer evaluation is run with the current and a candidate language model
- **THEN** it reports the same measures for both, and the candidate is adopted only if it meets the recorded pass criteria

#### Scenario: Criteria fixed in advance
- **WHEN** a candidate model is evaluated
- **THEN** the pass criteria it is judged against were recorded before its evaluation was first run
