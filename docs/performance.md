# Browser performance gates

Run `bin/check-performance --output /tmp/bowser-performance-$(date +%s)` on an
Apple Silicon Mac with a graphical login session. The runner builds a fresh
release stage. To reuse a build, pass `--stage PATH`, where PATH is the output
written to `BOWSER_STAGE_FILE` by `bin/install --stage-only`.

The runner uses disposable state under `/tmp`, synthetic registrations, loopback
pages, and telemetry disabled. It does not read the installed browser's session,
connect to its sockets, or install an update. Build, signing, fixture preparation,
and release copying happen outside measured intervals. Keep the machine idle and
unlocked; visible WebKit windows are required for paint and animation callbacks.

## Coverage

| Workload | What the interval measures |
|---|---|
| Native startup, 3 fresh processes | Spawn the release app to a valid native protocol hello. Includes window/tab creation; excludes backend startup. |
| Complete browser startup, 3 each | Spawn the app through normal backend bootstrap until 1 or 100 restored tabs are registered. Pages use a refused loopback destination; page paint is measured separately. |
| Backend startup, 3 fresh processes | Spawn the shipped backend helper to agent socket and initialized fixture mod. Uses a synthetic native peer. |
| Live backend upgrade, 3 | Candidate preparation to update acknowledgment, with a separate freeze/handoff pause measurement. Checks mod state and native connection survive. |
| Offline upgrade, 3 | Verified backup and activation with 32 MiB in 128 persistent files; checks backup, completion and preserved previous pair. Uses minimal bundle/runtime contents; download and app relaunch are excluded. |
| Live toolbar upgrade, 5 | Verify/load/adopt alternate signed native modules into a visible slot, plus a separate main-thread adoption budget. Signature verification normally runs off the main thread. |
| New tab, 5 | Create, activate and lay out a blank tab. |
| 100 restored tabs, 3 batches | Construct deferred tabs; assert no background navigation starts. Also records native host resident memory. |
| Cold navigation, 5 | Fresh webview and uncached loopback URL to native page reveal (visible layout, with load-finish fallback). |
| Cached tab, 5 | Mount a deferred fresh webview to native page reveal; assert no extra HTTP request. |
| Loaded tab switch, 30 | Activate and lay out tabs in an eight-tab loaded session. |
| Sleeping tab, 5 | Mount with cached preview/loading cover, then separately wait for native page reveal. |
| Omnibar, 30 | Query 1,000 tab candidates and produce suggestions. |
| Scroll, 120 frames | Animation-frame intervals during programmatic scrolling of a local page. |

The `_first_content_ms` metrics use Bowser’s reveal signal, which falls back to
load completion for empty pages or unavailable WebKit rendering callbacks; they
are not compositor presentation timestamps.

Fresh-process startup does not purge the OS disk cache. Cached-tab coverage uses
a unique persistent WebKit store shared by fresh views within the test process;
it does not restart the browser between cache priming and activation.
Memory is native host RSS, not aggregate WebKit child-process memory. The scroll
fixture detects frame stalls; it does not measure hardware input-to-display
latency. These deterministic gates complement real-site testing and Safari
comparisons; they cannot reproduce remote network congestion or every website.

## Budgets and CI

`tests/performance/budgets.json` defines required sample counts, absolute p95
limits, and noise allowances. `_ms` metrics use milliseconds; `_mb` uses MiB.
The evaluator uses nearest-rank percentiles. Missing workloads, short runs,
invalid values, failed behavioral assertions, and exceeded limits all fail.
Tests are opt-in (`BOWSER_PERF=1`) and run serially in the release configuration.

The Browser performance workflow runs on pull requests, main pushes, and manual
requests on `macos-26`. It restores a passing baseline saved only by main and
compares matching macOS, CPU, architecture, Swift toolchain and report schema.
A regression fails if p95 exceeds both 125% of the baseline and baseline plus the
metric's noise allowance. Absolute budgets always apply. A missing/incompatible
baseline is explicitly reported and the first passing main run establishes one.
Change the cache version when intentionally changing the workload definition.

The desktop release workflow also enforces absolute budgets against its freshly
built stage before publication. CI uploads raw samples, p50/p95 summaries,
XCTest results, environment details, and build/runtime logs, including failures.
Navigation diagnostics are retained before the disposable home is removed.
Budget failures print samples in collection order so a slow first load remains
visible rather than disappearing into an aggregate.
`--baseline PATH/report.json` enables the same comparison locally. The output
path must be new so previous samples cannot accidentally make a run pass.

Validate the gate logic with:

```sh
python3 -m unittest discover -s tests/performance -p test_report.py
```

Treat budget changes as reviewed product decisions. Investigate the workload and
artifact before increasing a threshold; shared CI runners have noise, but a
missing readiness signal must never be replaced with a fixed successful sleep.

## Safari comparison

Run the same local rendering fixture in Safari and the complete Bowser release:

```sh
bin/compare-safari --stage PATH --output /tmp/safari-comparison-$(date +%s)
```

Safari must have **Settings → Developer → Allow remote automation** enabled.
The runner does not change that setting. If enabled temporarily, turn it off
when testing finishes. Safari uses its isolated WebDriver windows; Bowser uses
a uniquely identified disposable app and home with the shipped backend. Neither
adapter closes personal browser windows or connects to the installed Bowser.

The default order is Safari, Bowser, Bowser, Safari, with one unmeasured warmup
and five measured navigations per batch: ten runs per browser. Both load the
same no-store HTML from one loopback server. All compared intervals come from
`performance.now()` or Navigation Timing inside the page, so WebDriver/IPC
round-trip latency is excluded. The scrolling/layout surface has identical
1000×650 CSS-pixel bounds; the report also checks matching inner content sizes
(scrollbars may consume space), display scale, visibility, and scroll distance.
A hidden page, clipped viewport, missing result, or incomplete sample set fails.

The report compares:

- Navigation start to two animation callbacks (not physical screen presentation).
- DOMContentLoaded completion.
- Forced layout after updating 1,000 rows, 20 iterations per navigation.
- Animation-frame intervals during 120 programmatic scroll steps.
- Percentage of scroll intervals longer than 50 ms.

Each navigation is one replicate. The comparison uses the median of per-run
p95s, retaining each run and its range in the artifacts. Adjacent frames are not
treated as independent benchmark runs. `safari-budgets.json` enforces a 25%
Safari-relative allowance plus a metric-specific absolute noise allowance;
long-frame rate may exceed Safari by at most two percentage points. Both
thresholds must be exceeded to fail a timing metric. These initial allowances
are explicit reviewable budgets, not statistical confidence intervals.

The CI performance job runs the comparison on the same hosted Mac after the
Bowser-only gates, enabling WebDriver on that disposable runner and uploading
both reports. Raw data, browser/build/OS/CPU details and logs stay in the output
directory.

This is a **page-rendering comparison**. It does not compare native cold launch,
tab-switch input-to-frame latency, or omnibar keystroke latency. Bowser's internal
timings and Safari WebDriver command timings have different boundaries and
must not be divided to claim a browser speed ratio. Those native UI acceptance
items remain tracked in `bowser-browser-ehu`; the existing Bowser-only CI gates
continue to cover their internal workloads.
