# Spec Delta

## MODIFIED Requirements

### Requirement: Image model identity
Each stored photo vector SHALL come from the installed embedding model, the same model that embeds passages, and record its identifier, version and dimension. Photo search MUST exclude photos whose recorded model, version or dimension differs from the installed embedding model.

#### Scenario: Embedding model changed
- **WHEN** the installed embedding model differs from the one recorded on stored photos
- **THEN** those photos are not returned by photo search, and they are returned again after their documents are re-indexed

### Requirement: Image relevance
Photo search SHALL report whether its best match is within a configurable photo-to-photo distance threshold. Typed words matched to photos SHALL use a separate, configurable text-to-photo threshold. Photos beyond the applicable threshold MUST NOT be presented as matches.

#### Scenario: Unrelated photo
- **WHEN** the user searches with a photo unlike any image in the library
- **THEN** no image is reported as a match

#### Scenario: Unrelated words
- **WHEN** the user asks about something no library photo shows
- **THEN** no photo is presented as matching the question

### Requirement: Images findable by text
Each stored image SHALL be findable by typed questions in two ways: by one searchable passage built from its caption, its section heading and the text recognized in it, and by the meaning of the question compared with the photo itself. A citation of an image's passage, and a photo matched by meaning, MUST identify the image.

#### Scenario: Caption search
- **WHEN** a manual has a photo captioned "Figure 3: Filter housing, rear view" and the user asks "show me the filter housing"
- **THEN** that photo's passage is among the retrieved results and its citation shows the photo

#### Scenario: Text inside the photo
- **WHEN** an imported photo shows a nameplate reading "FH-220" and the user asks "FH-220"
- **THEN** that photo's passage is among the retrieved results

#### Scenario: Uncaptioned photo found by meaning
- **WHEN** an imported photo of a red pump has no caption and no text on it, and the user asks "photo of the red pump"
- **THEN** that photo is presented as matching the question

### Requirement: Image retrieval quality baseline
The project SHALL maintain an image evaluation set of query photos with their expected library images, and of text queries with their expected photos. With the installed embedding model, similar image search MUST return the expected image in the top three results for at least 80% of the photo queries, text queries MUST return the expected photo in the top three for at least 70% of the text queries, and both thresholds MUST be tuned against the set whenever the embedding model changes.

#### Scenario: Image evaluation run
- **WHEN** the image evaluation is run with the installed embedding model
- **THEN** it reports top-three recall for photo queries (at least 80%) and for text queries (at least 70%)
