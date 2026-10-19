# Local history search

Open **Go → Search History** (⌘Y), choose a profile, and expand **Capture and
storage** to enable remembering pages. Enabling downloads a checksum-verified
388 MB EmbeddingGemma 2 text/vision model. The model is shared; each profile's
content and search vectors are stored in a separate SQLite database. History
also appears among command-bar results. Before the model is ready, keyword and
color-description search work locally.

Only an enabled profile's foreground, persistent HTTP(S) page is captured.
The collector runs in a separate WebKit content world. It observes visible
articles, paragraphs, headings, lists and images; copies bounded text before
virtualized elements are recycled; and derives color descriptions from applied
styles. It excludes editable fields, marked private content and hidden text.
The observer set, DOM traversal, message batches and pending queue are bounded.
After scrolling settles, a small viewport sample covers content beyond the
observer set. There is no continuous full-page screenshot or DOM archive.

When pictures are enabled, a fully visible image may be captured at most once
every eight seconds. Captures are limited to its rectangle and rejected when
editable content overlaps. Thumbnails are at most 384 pixels wide and 128 KB.
Canvas content, cross-frame content, brief glimpses and unsupported page
structures are not guaranteed to be captured. Permalinks are taken from generic
article markup when available; otherwise the saved source URL is opened.

The signed `BowserHistoryWorker` helper owns SQLite and LiteRT. It runs one CPU
thread at low priority, handles bounded requests over private pipes, has a
25-second request deadline and exits after 30 seconds idle. The browser does
not load the model into its UI process. Capture/indexing pause during camera or
microphone use, Bowser's capture mode, memory pressure and serious thermal
pressure. Generic screen sharing without camera/microphone use is detectable
only when AppKit reports a sharing session or capture mode is enabled.

Each profile is limited to 10,000 records and a 128 MB database, with 30-, 90-
or 365-day retention. The default is 90 days. The shared model is additional.
Expired and oldest records are removed as the index is used; deleting history
removes its text, picture and embeddings. Site exclusions also delete existing
records for the host and its subdomains. Disabling capture preserves existing
history so it can still be searched or cleared.

The local ranker combines SQLite FTS5 with normalized 512-dimensional text/image
vectors, then groups results by destination URL. Model identity is stored with
each vector; vectors from another version are never compared. The collector
uses no site-specific selectors.

## Dependency and validation

The native macOS runtime is pinned to LiteRT-LM v0.18.0, with a SwiftPM SHA-256
checksum. Installation thins the library to arm64, bundles and signs the helper,
and includes the runtime license. The model is pinned to Hugging Face revision
`e301f74d5551b0c2641bd5cb4652a76239d5c5f8`, SHA-256
`92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0`.

Run the history storage, capture and presentation tests with a temporary
`BOWSER_HOME`. Real-model smoke checks use synthetic text and generated solid
color image fixtures; they do not ingest personal browsing data.

Upstream: [model card](https://huggingface.co/google/embeddinggemma-2),
[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM/tree/v0.18.0).
