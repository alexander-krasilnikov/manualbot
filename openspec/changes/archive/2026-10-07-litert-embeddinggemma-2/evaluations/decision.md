# Language model decision: Gemma 4 E2B replaces Gemma 4 E4B

Run on 2026-10-06 on a Mac (Apple silicon), with `AnswerEvalTests` (`Packages/Adapters`), the baseline and the candidate one after
the other on the same library, suite (31 questions plus 6 follow-up pairs, 43 questions in all) and settings. The two
reports are `answer-eval-e4b.md` and `answer-eval-e2b.md`. The criteria are the ones design D11 fixed before the candidate
was first run.

| Measure | E4B (baseline) | E2B (candidate) | Criterion | Met |
|---|---|---|---|---|
| Cites a passage with the fact | 100% (37/37) | 100% (37/37) | at least baseline − 5 points, and at least 80% | yes |
| States the fact | 97% (36/37) | 100% (37/37) | at least baseline − 5 points | yes |
| Wrongly refused | 0 | 0 | at most baseline + 1 | yes |
| Answered when unanswerable | 0/6 | 0/6 | at most baseline | yes |
| Grounding failures | 0 | 0 | at most baseline + 1 | yes |
| Follow-up hits | 6/6 | 6/6 | at least baseline − 1 | yes |
| Median time to first text (reported, not a criterion) | 1.14 s | 0.38 s | | |
| Median text fragments per second (reported, not a criterion) | 45.5 | 76.5 | | |

`AnswerEvalReport.failedCriteria(comparedWith:)` applied the criteria and printed
`decision for Gemma 4 E2B against the baseline: ADOPT, every criterion is met`. A second run of the baseline gave the
same answers as the first (the sampler seed is fixed): only the timings moved.

**Decision:** the manifest's language model is now `gemma-4-e2b` (`gemma-4-E2B-it.litertlm`, 2,588,147,712 bytes, SHA-256
`181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`). An earlier E4B file is deleted at launch because the
manifest no longer lists it. The download is 1.1 GB smaller.

**Limits of the evidence.** One document set of six small documents, 37 answerable and 6 unanswerable questions, one sampler
seed, run on a Mac and not on an iPad. The one fact E4B missed (the answer said "a bath or a shower" where the expected
text was "water") is a wording difference, not a wrong answer. Speed and memory on a real iPad are still to be measured.
