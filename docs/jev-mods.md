# Jev for mods

`BowserBrain.Jev.evaluate(state, questions)` calls Bowser’s authenticated server,
which keeps the TypeSafe key private. It returns `{:ok, reply}` with string-keyed
`answers`, or `{:error, reason}`. The account must have completed free-AI setup.
Limits are 16 questions and 32 KiB per request, plus the account’s daily allowance.
Call from a bounded worker, not a mod’s event callback. Never send passwords,
cookies, form fields or unrelated private page content.

```elixir
BowserBrain.Jev.evaluate(%{"text" => "A visible post selected for filtering"}, %{
  "filler" => %{"type" => "noul", "instructions" =>
    "Is `text` generic promotional filler rather than concrete information?"}
})
```

Question types: Noul returns a `noul` probability; Choice takes a criteria map of
2–32 options and returns `choice`, `probabilities`, `confidence`; Score takes an
ordered criteria list of 2–10 levels and returns `score`, `probabilities`,
`confidence`. Each question has `type` and `instructions`; Noul optionally has
`criteria` with `true`/`false` descriptions. State and instructions accept strings,
objects or arrays. MCP exposes the same operation as `jev` with `state` and
`questions`. Assets and rendering limits are unchanged.

## Sample filters

- `beam/example_mods/x_quality_filter.ex` applies only to X.com.
- `beam/example_mods/amazon_quality_filter.ex` applies only to Amazon.com search listings.

Install the desired example through ModSmith or copy it into your profile’s mods
folder. These are opt-in because visible post/listing excerpts are sent to Bowser
and TypeSafe. They never inspect DMs or input fields, click site actions, or
transmit cookies. Amazon regions need a separately scoped example; the sample
does not silently claim every Amazon domain.

The floating Quality filter button pauses filtering and restores content. Each
covered item has a Show button. Only judgments with filler probability >=0.95
and useful-information probability <=0.15 are covered. Uncertain results, missing
credentials, quota exhaustion and outages leave content visible. This is a
content-quality heuristic, not proof that an author used AI or a product is bad.

Each sample request evaluates one visible item, using one worker at a time and at most
500 cached decisions, with backoff after errors. Covers preserve layout geometry: X’s
virtualized cells and their ancestor transforms are never removed or modified.
Results for recycled cards or changed text do not apply to different content.

## Learn exercises and development logs

ModSmith chooses Jev for semantic filtering from the user’s requested outcome.
Users do not need to mention Jev, caching, selectors or failure handling. Exact
text matches and structural UI changes use deterministic code instead. Generated
Jev mods classify new content at runtime, cache judgments and leave uncertain
results or service errors visible. On trusted Learn pages, the browser supplies
the same live-filter contract: observe newly inserted and edited items, including
recycled cards, and evaluate them as they arrive. Deduplicate in-flight work,
bound concurrency and queue arrivals rather than losing them while a request is active.
Cache by content and filter criteria; never apply an old judgment to replacement
content. Verify insertion and editing, and remove temporary test data afterward.
The browser also supplies
the exercise scope and guide boundaries automatically. They are generation exercises: no filter runs until the user creates a
mod. Existing generated mods are not changed by editing the guide prompt.

Hosted-service operators can inspect `ai` request lifecycle logs in the private services project. Each request
has a correlation ID, `kind=chat` or `kind=jev`, start/completion/failure, elapsed
milliseconds, and billed units on success. Failures include the HTTP status and
sanitized error code. Credentials, email addresses, request content and provider
response bodies are not logged. A `kind=jev event=complete` line confirms a real
Jev request completed; a generated filter alone is not evidence of a provider call.

For listing/post filters, send one item per Jev request. Multiple questions can
concern that same item. Cache valid confident decisions by content and criteria
version; missing or malformed answers must remain visible and must not become
cached keep decisions.

## Default generated filter controls

ModSmith defaults page-specific filters to compact in-page controls beside the
content they affect. Browser-wide native toolbars/panels are for browser-wide
features, explicit owner requests, or requirements that cannot be met in-page.
Controls stay in the requested site/demo scope, have accessible names, avoid
obscuring site content, and are excluded from observation and classification.

Show progress by default: **16 found · 12 evaluated · 3 hidden**, with **4 pending**.
“Found” counts unique eligible items for the current page/feed. “Evaluated” counts
valid completed judgments for current content and criteria, including keep and
uncertain results; matching cached judgments count too, with reuse shown separately
(e.g. **8 cached**). Queued requests and failed/malformed replies do not count as
evaluated. Show uncertainty, failures, pause, service unavailability, or application
errors explicitly. “Hidden” counts items actually hidden, not planned decisions.

**16 found · 16 evaluated · 0 hidden** is a successful all-keep result.
**No matching items found** means detection found nothing. Deduplicate repeated
scans/retries, update on new/edited/removed content and toggles, reset on navigation,
and isolate each tab's counters. Verify visible counts using controlled fixtures
and remove fixture effects afterward. These are generation instructions; existing
installed mods acquire the UI when refined, not automatically from a prompt update.

## Correction-based personalization

For subjective preference mods, ModSmith automatically considers optional in-page
corrections such as Keep/Hide or More/Less like this. Fixed-behavior requests,
objective rules and layout changes do not need learning controls. Ratings must
not block normal use.

Generated mods persist explicit user labels, clean item snapshots and optional
reasons separately from model caches. Exact-item overrides win; a single correction
does not establish a brand-wide rule. For a new item, a bounded selection of relevant
labeled examples can accompany the target in structured state or instructions.
There is one target per request, and examples are supporting context within the
existing 32 KiB limit. This remembers preferences and supplies context; it does not
train Jev's model weights or use an invented training API.

Provide undo/edit/reset and a personalization pause. Cache keys include a preference
version; reject in-flight results for older versions. Exclude mod UI from extracted
content. Silence, model outputs and request failures are not user feedback.

Verification covers persistence, corrections, undo/reset, stale caches and a
different item evaluated using saved examples. Generalization requires separate
labeled cases, not replay of the corrected item. Remove synthetic feedback after
testing, preserve user feedback, and distinguish tested behavior from unproven
accuracy improvements.

References: [structured questions](https://docs.typesafe.ai/primitives/advanced),
[state](https://docs.typesafe.ai/concepts/state),
[HTTP API](https://docs.typesafe.ai/api).
