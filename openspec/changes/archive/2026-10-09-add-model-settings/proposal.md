# Proposal

## Why

The app can run only the two models compiled into its manifest (EmbeddingGemma 2 and Gemma 4 E2B). Trying a smaller or newer model, or going back to E4B on a larger iPad, needs a new build. LiteRT-LM v0.18.0 can already run other `.litertlm` models, and it can describe a file (`ModelInfo`: model type, minimum runtime version, context size, embedding dimension, input modalities), so the app can offer them safely if it checks them first.

## What Changes

- **A Models page in Settings** for finding, downloading, installing, activating and deleting models, one active model per role (embedder and language model).
- **Embedders come from a built-in list that ships with the app, and from search.** A list entry carries what the code needs to use it well and cannot read from the file: prompt templates, output dimension, input token limit, chunk sizes and relevance thresholds, and was tested. An embedder found by search has none of that: it is used with generic settings and labelled untested.
- **Models can be found by search** on Hugging Face (`litert-community`, `.litertlm` files, repositories that are not gated), language models and embedding models alike. This is the only place the app goes online after setup, and only when the user asks.
- **Compatibility is checked twice.** Before download, a small range request reads the file header (model type, image support, format version), and the file size is compared with free storage and the device's memory. After download, the runtime's `ModelInfo` decides: wrong type, a newer runtime required, or too small a context removes the file and says why.
- **Every download is verified by SHA-256**: the catalog's checksum, or the LFS checksum Hugging Face reports for the file.
- **Installed models can stay inactive**, so switching back is instant. Models the user installed or activated on the Models page are deleted only when the user asks. **BREAKING:** the launch clean-up no longer deletes every model the built-in manifest does not list; it still deletes a replaced default the user never chose.
- **Activating a model asks for confirmation that names its cost**, then switches straight away. Running work (an answer being written, indexing) is cancelled. A new embedder re-indexes the library automatically, as an app update already does. Photo search is off until the re-index finishes, or for as long as the active embedder cannot embed images.
- **First run is unchanged**: the setup screen still installs the default pair from the built-in manifest.
- **About lists the installed models** with their licences, instead of a fixed list.

## Capabilities

### New Capabilities
- `model-catalog`: what models the app can offer (the curated embedder catalog and language model search), how their compatibility is judged before and after download, and how they are installed, activated and deleted from the Settings page.

### Modified Capabilities
- `model-provisioning`: the built-in manifest defines the defaults for first run instead of being the only allowed list; licences come from installed models; recovery and readiness refer to the active model of each role; the offline guarantee names Settings as the only user-initiated network use.

## Impact

- **Ports**: `ModelSpec` gains a licence and repository. A model record (source, whether the user chose it) and a persisted active selection per role. Model search, header probe and validation ports.
- **Adapters**: a Hugging Face search client (plain `URLSession` against the public API), a `.litertlm` header reader using HTTP range requests, a `ModelInfo`-based validator. `LiteRTEmbedder` and `Chunker` take a profile instead of EmbeddingGemma 2 constants. `FileModelFiles.removeUnlisted` keeps installed models.
- **Core**: `ModelStore` tracks installed, inactive and active models and downloads models that are not in the manifest. An embedder profile type (prompts, dimension, input limit, chunker, relevance distances) and the embedder catalog live here; thresholds are read from the active embedder's profile.
- **App**: a Settings entry with the Models page; `AppModel` tears down and rebuilds the services when the active model changes; `ServiceFactory` builds from the active selection; About lists installed models; the X-ray network indicator treats Settings traffic as user-requested.
- **Evaluation**: each curated embedder other than EmbeddingGemma 2 needs its prompts and thresholds settled by the existing retrieval evaluation before it is listed.
- **Data**: switching embedders re-indexes every document once. Chats and originals are unaffected.
