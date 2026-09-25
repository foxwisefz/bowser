# Topic Filter

Topic Filter is an opt-in Bowser mod. Open `:topic-filter` for native settings.
Enable the post-text consent switch and filtering, select topics and sites, then
choose **Save and apply**. The page’s **Turn on…** button opens these settings;
Resume only resumes a filter that is already enabled. It uses the existing Bowser account and Jev service.

Eight presets cover politics, rage bait, doom framing, mockery, harassment,
engagement bait, cryptocurrency and generic filler. Generic filler is a content
quality judgment, not an assertion of AI authorship. Add up to 20 custom topics,
one per line; delete a line to remove that topic. Preferences persist across
browser restarts. Sensitivity thresholds are Relaxed 80%, Balanced 65%, and
Strict 50%; these are configurable behavior choices, not measured accuracy claims.

Supported content:

| Site | Content |
| --- | --- |
| X | Timeline, search and profile posts; no messages or notifications |
| Reddit | Modern and old Reddit posts/comments; no message or chat routes |
| YouTube | Comments, not video recommendations |
| Hacker News | Story titles and comment text |
| LinkedIn | Main feed post text |

Cover preserves item geometry. Dim fades an item and offers Show. Remove hides
content with a Show control; X uses a cover even in Remove mode to preserve the
virtualized timeline. HN filters the text within a row and leaves nested replies
available. Show hidden reveals everything in that tab. Pause this tab stops new
requests and restores content; native settings also offer a one-hour pause across
tabs. Saving settings ends the one-hour pause.

The page status reports found, evaluated, hidden, pending, cached and uncertain
items for currently mounted feed content. Counters reset on navigation. A successful
all-keep result can have zero hidden items. Service errors stay visible, leave
unclassified content visible and retry after a minute. Selected post text, which
may itself contain personal information, goes to Bowser and TypeSafe. Extractors
do not add author identities, URLs, input fields or message inboxes to requests.
Settings are stored locally; classification answers and text fingerprints are
cached only in memory, up to 1,000 entries. No post text is persisted by this mod.

Each request evaluates one post. All selected questions are grouped together,
split into groups of 16 only when the service question limit requires it. Up to
three evaluations run concurrently across tabs. Changed text, navigation and
settings invalidate stale applications. Cached raw probabilities can be reused
when sensitivity or presentation changes. Individual Show overrides last until
navigation or settings reinjection; they do not train a preference model.

The server connection requires a registration receipt in Bowser’s data directory
and the matching server endpoint. ModSmith provider keys alone do not authenticate
Jev requests. A missing receipt is an account-connection problem, not a request to
replace the configured model provider.

The implementation uses native mod settings and the Bowser service. It has no
separate subscription, provider-key form, daily allowance or usage-history chart.
Website selectors may need updates as sites change; controlled WebKit fixtures
verify DOM behavior, not model accuracy or every live site layout.

## Installation

Run `bin/install-topic-filter` from the checkout. It packages the policy, page
script and mod into `~/.bowser/mods/topic_filter.ex` for the live loader. No browser
restart or full runtime update is needed. `--output path` builds an isolated package
for inspection. Re-running the installer updates the mod and preserves settings.

## Development validation

```sh
cd beam
mix test test/topic_filter_test.exs test/quality_filter_test.exs
```

From the repository root:

```sh
swiftc -swift-version 6 -module-cache-path /tmp/bowser-topic-module-cache tests/topic-filter/main.swift -o /tmp/bowser-topic-filter-probe
/tmp/bowser-topic-filter-probe "$PWD/beam/priv/topic-filter.js"
```

The WebKit probe uses synthetic pages in a nonpersistent data store and a mocked
message bridge. It never calls Jev or modifies the live browser.
