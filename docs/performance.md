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
| Live toolbar upgrade, 31 | Verify/load/adopt alternate signed native modules into a visible slot. First adoption of the replacement generation has its own budget; the next 30 alternate already-used generations with a separate main-thread adoption budget. Signature verification normally runs off the main thread. |
| New tab, 5 | Create, activate and lay out a blank tab. |
| 100 restored tabs, 3 batches | Construct deferred tabs; assert no background navigation starts. Also records native host resident memory. |
| Fresh-profile navigation, 1 | First navigation in a unique persistent WebKit store to native page reveal. Includes first-use work after navigation begins; store/view construction is outside the interval. |
| Cold navigation, 5 | Fresh webview in the initialized store and uncached loopback URL to native page reveal (visible layout, with load-finish fallback). |
| Cached tab, 5 | Mount a deferred fresh webview to native page reveal; assert no extra HTTP request. |
| Loaded tab switch, 30 | Activate and lay out tabs in an eight-tab loaded session. |
| Sleeping tab, 5 | Mount with cached preview/loading cover, then separately wait for native page reveal. |
| Omnibar, 30 | Query 1,000 tab candidates and produce suggestions. |
| Scroll, 120 frames | Animation-frame intervals during programmatic scrolling of a local page. |

The `_first_content_ms` metrics use Bowser’s reveal signal, which falls back to
load completion for empty pages or unavailable WebKit rendering callbacks; they
are not compositor presentation timestamps.

With `BOWSER_PERF=1`, reports also include per-switch detach, mount, responder,
chrome, toolbar, and layout durations, plus navigation callback timestamps from
the native load/resume request. These distinguish synchronous activation work
from WebKit startup and the delay before Bowser observes content. Callback
timestamps and the page's Navigation Timing entries have different origins;
do not subtract one clock's values from the other. Diagnostic serialization
runs outside the measured workload. Base revisions without these optional host
fields report `null` diagnostics while retaining the same measured workloads.

Full browser startup also saves `browser-<tab-count>-<sample>-probes.json`,
including failed probes, elapsed time, reply latency, and restored tab count.
Use these with the shell and backend logs to distinguish backend startup from
tab restoration and slow readiness replies. Probe files are saved after timing
ends, including when startup fails.

CI confirms a candidate that fails only a browser revision-relative baseline
with a second pair on the same runner, measuring candidate before base. The
same relative limit must fail in both pairs to block the change. Absolute
budget violations, incomplete measurements, and incompatible references fail
without confirmation. Both pairs and their phase traces are uploaded.

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
Fresh-profile first content has a 2,000 ms cap and first-generation toolbar
adoption a 50 ms cap. These explicit first-use allowances are separate from the
unchanged 750 ms uncached-navigation and 16.67 ms repeat-adoption caps. First-use
measurements are required single samples, not discarded warmups; their reported
p50 and p95 both equal that observation. This separation does not make a 50 ms
main-thread adoption frame-smooth. All 31 toolbar upgrades also retain the
750 ms total-upgrade gate. Report schema version 3 identifies these workloads and sample counts.
For 30 repeat adoptions, nearest-rank p95 is the second-slowest observation.
The maximum is also reported for every metric; no samples are discarded.

The evaluator uses nearest-rank percentiles. Missing workloads, short runs,
invalid values, failed behavioral assertions, and exceeded limits all fail.
Tests are opt-in (`BOWSER_PERF=1`) and run serially in the release configuration.

The Browser performance workflow runs on pull requests, main pushes, and manual
requests on `macos-26`. It builds the candidate and a pinned base revision,
then measures both serially in the same job, using identical benchmark fixtures.
Pull requests use their base SHA, main pushes use the previous main SHA, and
manual runs use the selected commit's first parent. A missing base commit fails
explicitly. No timing baseline is restored from another runner's cache.

The candidate's performance harness is copied into the disposable CI base source
checkout; production code and build tools remain at the base revision. Reports
record both source SHAs, the harness revision, and the shared run/attempt/job ID.
Incompatible fixtures or failed/incomplete reference measurements fail the job;
they never silently disable relative comparisons. A complete reference may
exceed an absolute budget: its measurements remain usable, but the candidate
must still pass every absolute cap. Both reports and diagnostics are uploaded.

A regression fails if p95 exceeds both 125% of the base measurement and that
measurement plus the metric's noise allowance. Absolute budgets always apply.
Same-runner measurement reduces differences between machines; sequential runs
can still experience different load, so raw samples remain essential evidence.

The desktop release workflow also enforces absolute budgets against its freshly
built stage before publication. CI uploads raw samples, p50/p95 summaries,
XCTest results, environment details, and build/runtime logs, including failures.
Navigation diagnostics are retained before the disposable home is removed.
Budget failures print samples in collection order so a slow first load remains
visible rather than disappearing into an aggregate.
Toolbar adoption also reports opt-in phase durations for creation, mounting,
snapshot update, retirement, activation, layout, and responder restoration.
Sample 0 is first use; samples 1–30 correspond to the repeat-adoption samples.
These diagnostic timings leave the overall timed boundary and budget intact.
Reports are printed after the measurements, not inside timed blocks. Older base
revisions without the diagnostic accessor still run the same workload.
`--reference` collects a reference locally (threshold violations are reported,
but incomplete measurements fail its exit status). `--baseline PATH/report.json`
requires a complete compatible reference; missing reports fail. Set the same
`BOWSER_PERF_SESSION` for paired local runs to enforce session matching. The output
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

Safari comparison reports `FAIL` when complete measurements exceed a relative
budget, and `INCOMPLETE` when execution or measurement validation fails. Both
exit nonzero. The table includes the enforced limit and each browser's range of
per-run p95s; ranges describe spread, not confidence intervals. Existing relative
thresholds and noise allowances apply regardless of how narrowly a metric fails.
