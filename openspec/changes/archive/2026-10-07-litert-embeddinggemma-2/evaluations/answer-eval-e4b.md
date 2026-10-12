# Answer evaluation: Gemma 4 E4B

Settings: temperature 0.2, at most 512 answer tokens, top-k 40, top-p 0.95, sampler seed 0, GPU; retrieval with EmbeddingGemma 2 (256 dimensions, passages of about 130 tokens, relevance threshold 0.28, six passages)

| Measure | Result |
|---|---|
| Questions | 37 answerable, 6 unanswerable (6 follow-ups among them) |
| States the expected fact | 97% (36/37) |
| Cites a passage containing it | 100% (37/37) |
| Wrongly refused | 0/37 |
| Answered when unanswerable | 0/6 |
| Grounding failures | 0 |
| Follow-up hits | 6/6 |
| Median time to first text | 1.14 s |
| Median text fragments per second | 45.5 |

## Every question

| Kind | Question | Outcome |
|---|---|---|
| single | How do I reset the X200 to factory defaults? | states, cites |
| single | What does error E-042 mean? | states, cites |
| single | The filter light says E-107, what is wrong? | states, cites |
| single | What is the part number of the replacement filter? | states, cites |
| single | How often should I change the HEPA filter if I have pets? | states, cites |
| single | How do I connect the purifier to my wifi? | states, cites |
| single | How loud is the air purifier on its highest setting? | states, cites |
| single | How do I clean the dirty air quality sensor? | states, cites |
| single | How long is the warranty? | states, cites |
| single | Does the warranty cover damage from unauthorized repairs? | states, cites |
| single | What do I need to send in when making a claim? | states, cites |
| single | Can I give the warranty to someone else if I sell the product? | states, cites |
| single | What pressure should my mountain bike tyres be at? | states, cites |
| single | When should I replace the chain? | states, cites |
| single | What torque for the M6 seatpost clamp? | states, cites |
| single | My brakes squeal, why? | states, cites |
| single | What is the default Wi-Fi password of the router? | states, cites |
| single | What does a blinking red light on the router mean? | states, cites |
| single | How do I factory reset the router? | states, cites |
| single | What is the address of the router admin page? | states, cites |
| single | How do I descale the coffee machine? | states, cites |
| single | What does error C-14 mean on the coffee machine? | states, cites |
| single | How often do I need to empty the drip tray? | states, cites |
| single | What should I do if I smell gas? | states, cites |
| single | Can I use the appliance near a bathtub? | no fact, cites |
| single | What is the capital of France? | refused (correct) |
| single | Who won the football world cup in 2010? | refused (correct) |
| single | Write me a poem about the ocean | refused (correct) |
| single | How do I bake sourdough bread? | refused (correct) |
| single | Explain how quantum computers work | refused (correct) |
| single | What is the best restaurant in Rome? | refused (correct) |
| pairFirst | How do I reset the X200 to factory defaults? | states, cites |
| followUp | What does that erase? | states, cites; rewrite hit |
| pairFirst | What does error E-107 mean on the X200? | states, cites |
| followUp | How often should I replace that filter? | states, cites; rewrite hit |
| pairFirst | How long is the warranty? | states, cites |
| followUp | And how long are the filters covered? | states, cites; rewrite hit |
| pairFirst | What pressure should my mountain bike tyres be at? | states, cites |
| followUp | And for a road bike? | states, cites; rewrite hit |
| pairFirst | How do I factory reset the router? | states, cites |
| followUp | How long do I hold it? | states, cites; rewrite hit |
| pairFirst | How do I descale the coffee machine? | states, cites |
| followUp | How often should I do that? | states, cites; rewrite hit |
