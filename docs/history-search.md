# Local history search

Open **Go → Search History** (⌘Y) for a dedicated `bowser://history` browser tab.
History opens in the current profile, with an **All profiles** option.
The list shows page titles, websites and times. Click a title to reopen the
page, or inspect an entry to see its saved details. Switch to Gallery to
browse by page preview. Both layouts group visits by profile and start a
new time block after 30 minutes of inactivity or at the start of a new day.
The display menu can hide the website labels on each block.
Press ⌘F to search titles, URLs, saved text or descriptions. Use the date
and website filters together to narrow the results. **Reset** clears the
search and both filters while keeping the selected profile. You can select
individual entries or an entire time block for deletion.
Older captured content is labeled with its capture time rather than presented
as a visit that was never recorded.

The gear opens **History settings**, where recording, pictures, retention,
exclusions and clearing a profile are configured. Recording is opt-in.
Enabling downloads a checksum-verified
388 MB EmbeddingGemma 2 text/vision model. The model is shared; each profile's
content and search vectors are stored in a separate SQLite database. History
also appears among command-bar results. Before the model is ready, keyword and
color-description search work locally. The saved-status indicator reports the
last visit actually persisted to disk, with an explicit error if saving fails.

Lightweight visits (URL, title and time) save independently of the model and
content capture. Repeated navigations retain separate timestamps. Visits and
ordinary search continue during calls and resource pressure. Private browsing,
disabled profiles and excluded sites are not recorded. Deleting an open page's
current visit suppresses recapture until the next navigation; clearing a profile
does the same for its open pages.

Only an enabled profile's foreground, persistent HTTP(S) page is captured.
The collector runs in a separate WebKit content world. It observes visible
articles, paragraphs, headings, lists and images; copies bounded text before
virtualized elements are recycled; and derives color descriptions from applied
styles. It excludes editable fields, marked private content and hidden text.
The observer set, DOM traversal, message batches and pending queue are bounded.
After scrolling settles, a small viewport sample covers content beyond the
observer set. There is no continuous full-page screenshot or DOM archive.

When pictures are enabled, each visit may also receive one foreground page
preview after loading settles. It is at most 480 pixels wide and 64 KB, and is
skipped during resource pressure, calls, capture mode, or when editable or
sensitive content, video or embedded frames are detected. Missing previews are
shown explicitly; recording a visit does not depend on capturing a picture.

A fully visible image may additionally be captured at most once
every eight seconds. Captures are limited to its rectangle and rejected when
editable content overlaps. Thumbnails are at most 384 pixels wide and 128 KB.
Canvas content, cross-frame content, brief glimpses and unsupported page
structures are not guaranteed to be captured. Permalinks are taken from generic
article markup when available; otherwise the saved source URL is opened.

An off-main-actor repository handles lightweight SQLite visit reads and writes.
The signed `BowserHistoryWorker` helper handles content indexing and LiteRT with
its own SQLite connection. It runs one CPU
thread at low priority, handles bounded requests over private pipes, has a
25-second request deadline and exits after 30 seconds idle. The browser does
not load the model into its UI process. Capture/indexing pause during camera or
microphone use, Bowser's capture mode, memory pressure and serious thermal
pressure. Generic screen sharing without camera/microphone use is detectable
only when AppKit reports a sharing session or capture mode is enabled.

Each profile is limited to 10,000 visits and content records combined and a
128 MB database, with 30-, 90-
or 365-day retention. The default is 90 days. The shared model is additional.
Expired and oldest records are removed as the index is used; deleting history
removes selected visits and their previews; associated text, pictures and
embeddings are removed when the last recorded visit to that URL is deleted.
Deleting a saved-content entry removes that capture. Site exclusions also delete existing
records for the host and its subdomains. Disabling capture preserves existing
history so it can still be searched or cleared.

History shows a warning at 90% of either the storage or item limit. When either
limit removes older items, a notice above the capture controls records how many
items have been removed and the most recent removal time. The notice stays with
that profile across restarts, even after cleanup brings usage below the limit;
clearing all of the profile's history resets it. Retention expiry is explained
beside the capture toggle and does not trigger a capacity warning.

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
