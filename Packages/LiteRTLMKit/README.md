# LiteRTLMKit

Vendored Swift wrapper for [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM), Apache-2.0 (see `LICENSE`).

- Source: upstream tag `v0.17.1`, directory `swift/` (tests, `apple_fm` and `BUILD` files omitted).
- Binaries: the `CLiteRTLM` / `CLiteRTLM_mac` xcframeworks from the same release, pinned by checksum in `Package.swift`.
- Why vendored: the upstream repository stores files in Git LFS and one object is missing at this tag, so a normal
  SwiftPM checkout fails without `git-lfs` and `GIT_LFS_SKIP_SMUDGE=1`.

To update: copy `swift/*.swift` from the new tag (same exclusions), update the URLs and checksums from upstream's
`Package.swift`, and re-run the Adapters tests.

## Local patches

- `Conversation.deinit` deletes the native conversation on a background queue (and keeps the engine alive until it is
  gone). Upstream deletes synchronously; when the native callback thread drops the last reference to a conversation
  (which happens whenever the caller lets go of it before the final stream callback runs, such as when a request is
  stopped), the delete waits on the very thread it is running on and the process hangs. Worth reporting upstream.
