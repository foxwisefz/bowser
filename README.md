# Bowser

**Bowser: the browser that builds itself.**

A personalizable browser for Apple Silicon Macs. Every surface — chrome, tabs,
omnibar, panels, and the *websites themselves* — is moddable, live, with
no restart. Mods are Elixir processes, usually written on demand by an AI
agent, hot-loaded into the running browser in under a second.

Type `:do remove the side panels and leave only the timeline` into the
omnibar and an LLM writes, installs, and hot-applies the site mod while
you watch.

## How it works

```
┌──────────────────────────────────────────────┐
│  Shell (Swift, AppKit + SwiftUI leaves)      │  windows, tabs, omnibar,
│  owns WKWebView engine views                 │  panels — thin, fast
├──────────────────────────────────────────────┤
│  Brain (Elixir / BEAM)                       │  every mod = a supervised
│  mod runtime, hot reload, session memory     │  OTP process
└──────────────────────────────────────────────┘
```

The two talk over a Unix socket (`~/.bowser/brain.sock`, JSON protocol).
That protocol is the engine abstraction: the shell currently implements it
with WKWebView (see `brain/decisions/0008`); a dormant Rust/Servo host
lives in `host/`, revivable behind the same boundary.

The brain is the differentiator:

- **Mods are OTP processes.** The supervisor can restart a crashing mod. Mods
  run with your user account’s privileges, not in an extension sandbox. Only
  run code you trust. Edit a mod’s `.ex` file to hot-swap its code.
- **Native windows outlive backend updates.** The installed app uses a compiled
  Swift helper to own BEAM processes and relay their connection. Compatible
  releases transfer their state while existing WKWebViews stay alive. Elixir/OTP
  still supervises mods and hot-loads their code. Native changes wait until
  Bowser and its saved apps quit.
- **No extension store, ever.** You build the exact mod you want, the
  moment you want it (see `brain/decisions/0004`).

## Build from source

Bowser targets **Apple Silicon and macOS 15+**. You need Xcode 16+ (Swift 6),
Elixir 1.18+, Erlang/OTP, and Python 3 for the optional AI setup helper and tests.
The Rust/Servo prototype is not required for the WKWebView browser.

```sh
git clone https://github.com/foxwisefz/bowser.git
cd bowser
swift build --package-path shell -Xswiftc -DBOWSER_COMMUNITY
export BOWSER_HOME="$HOME/.bowser-community"
python3 bin/configure-ai  # optional: use your own OpenAI or Anthropic key
cd beam
mix deps.get
iex -S mix
```

`BOWSER_COMMUNITY` builds open directly without an account or invite. They do
not send Bowser telemetry or start automatic official-release updates. AI is
optional; configure your own provider to generate mods. Ordinary browsing and
locally written mods work without the private service. Rebuild with the same
flag when updating from source. Builds without that flag retain official
account admission and hosted-service behavior.

Use a separate `BOWSER_HOME` to keep source-build tabs, mods, settings and
website data separate from an installed Bowser. The API server, marketing
website and production deployment are maintained in a separate private project;
they are not required for this source-build workflow.

A browser window appears. `⌘K` opens the command bar: type a URL, or a
`:command`. Useful ones out of the box: `:settings`, `:panels`, `:do`.
`⌘T` new tab, `⌘⇧[`/`⌘⇧]` cycle tabs, `⌘R` reload, `⌘0/+/-` zoom.
**View → Picture in Picture** (`⌥⌘P`) toggles a floating player for a supported
video on the current page. Some embedded players require their own PiP control.
Open local HTML, images, PDFs or text with **File → Open File…** (`⌘O`),
Finder’s **Open With → Bowser**, or a `file:///…`, `/…` or `~/…` path in `⌘K`.
Local HTML can load assets from its containing directory.

Prefer to run the browser without the brain? `shell/.build/debug/Bowser`
runs standalone (start order doesn't matter — they find each other).
`BOWSER_NO_SPAWN=1` stops the brain from spawning its own browser.

For the installed app, run `bin/install`, then open Bowser normally. The installer
uses an existing `/Applications/Bowser.app`, or installs to `~/Applications/Bowser.app`. Updates activate after Bowser, its backend, and saved apps have
quit; installation never restarts them. The app starts its backend automatically. Closing a window leaves
Bowser running; opening it from the Dock creates a window again. **Quit Bowser**
(or ⌘Q) saves the session before closing windows and stops the backend and its
mod processes. Backend startup failures show a retry dialog with the log path.

For separate `/Applications/Bowser.app` and `/Applications/Bowser-staging.app`
using the same live sessions and website logins, run `bin/staging update`. Staging takes a verified build-and-data backup before
activation and offers **Update Staging from Dev…** in the app menu. See
[staging and recovery](docs/staging.md) for backup coverage and restore commands.

Installed builds include the BEAM release and native Swift executables for backend
ownership, update activation, detached launching, and the ModSmith MCP bridge.
They do not require Python, Elixir, or Xcode on the customer's Mac. Python is
used only by developer tests and experiment scripts. Run the native-helper tests
against the built release with:

```sh
swift build --package-path shell
BOWSER_TEST_RELEASE="$PWD/beam/_build/prod/rel/bowser_brain" python3 -m unittest discover -s tests
```

Saved apps support page notifications (`new Notification`) while running, with
website permission and macOS notification authorization. Notification clicks
return to that app. Background Web Push and service-worker notifications are
not implemented; Safari’s support does not imply public WKWebView support.
Saved apps display Dock badges from `navigator.setAppBadge()` /
`clearAppBadge()`, with leading unread counts such as `(2)` in page titles as a
fallback. There are no site-specific unread-count scrapers. macOS must allow
badge icons for the saved app.
Badges reflect the running website’s session, not the separate desktop
app, and clear on navigation or when the page closes.

For a development browser with no mods or site tweaks loaded, run
`bin/dev start --temp` after building the shell. Each start uses a fresh
temporary `BOWSER_HOME`, with separate sockets and session data, and skips
copying your personal mods, sites, profiles and settings. Stop an existing
dev brain with `bin/dev stop` first. The launcher prints the directory and
log command; the directory stays available after stopping and can then be
deleted. Plain `bin/dev start` keeps the usual seeded `~/.bowser-dev` profile.

### Your first mod

```sh
cp beam/example_mods/hello.ex ~/.bowser/mods/
```

Running in under a second — no restart. Edit the file: it hot-swaps.
Break it: the compile error is logged and the old code keeps running.
More examples in `beam/example_mods/` (a dock, a tab tree, an HN
rewriter, a Twitter nav mirror). From `iex`, drive the browser directly:

```elixir
BowserBrain.Browser.navigate("https://example.com")
BowserBrain.Browser.eval_js("document.title")
```

Per-site tweaks are even simpler: drop `.css`/`.js` files into
`~/.bowser/sites/<host>/` and they hot-apply to that host, no Elixir
needed.

### Letting the AI write your mods (`:do`)

`:do <request>` in the omnibar hands your request, the live page, and a
mod-API cheatsheet to the [claude CLI](https://claude.com/claude-code),
which writes and installs the mod — inspecting the real page over an MCP
bridge as it works. `:do+ <refinement>` iterates on the last one.

ModSmith also has a native workspace under **View → ModSmith…**. Choose
**This site** or **Across Bowser**, describe a change, and continue refining
that same mod. The workspace keeps the conversation, reported checks and
caveats together. Saved apps use the same workspace with app-only scope.

**Undo last change** restores the mod files captured before draft generation,
including drafts left by a failed run. It does not reverse website actions or
stored mod data. **Disable** pauses the whole mod. Existing conversations are
imported; their older changes do not gain retroactive undo history.

See [ModSmith workflow](doc/modsmith.md) for the protocol, persistence and
isolated development setup.

Auth is either of (details in `beam/README.md`):

- **Your own Claude login** — install the CLI, run `claude` once, done.
- **A router** — `:set dodorouter_endpoint <url>` and
  `:set dodorouter_api_key <token>` in the browser.

## Repo map

| Path | What |
|---|---|
| `shell/` | Swift shell: AppKit chrome, WKWebView engine views, SwiftUI surfaces |
| `beam/` | The brain: mod runtime, session resurrection, ModSmith (`:do`) |
| `beam/example_mods/` | Working mods to copy and mutate |
| `brain/` | Vision, architecture, ADRs, post-mortems — read before proposing changes |
| `doc/` | How each subsystem works |
| `host/` | Dormant Rust/Servo engine host (`brain/decisions/0008`) |
| `bin/` | Engine wrapper, MCP bridge, host rebuild script |

## Contributing

Start with `brain/README.md` and `brain/vision.md` — the pillars (speed
as base, this machine only, extensibility like never seen before) are
settled, and ADRs in `brain/decisions/` are reopened by filing an issue,
not by building around them. Every change ships with tests:

```sh
cd beam && mix test
cd shell && swift test
```

This repo is tracked with [beads](https://github.com/gastownhall/beads)
(`bd`) for issues and [jj](https://jj-vcs.github.io/) (colocated with
git) for version control.

Native command-toolbar, Deck Tabs and sidebar-renderer changes can be published with `bin/install --native-only`
after the module-capable signed host is installed. See
[the native rendering update boundary](docs/native-toolbar-updates.md) for signing,
activation and restart behavior.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and checks. Source code
is available under the [MIT license](LICENSE). Dependencies retain their own
licenses. See [NOTICE](NOTICE) for branding and artwork scope.
