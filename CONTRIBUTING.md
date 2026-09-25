# Contributing

Build and launch using the source instructions in README.md. Keep development
profiles isolated with `BOWSER_HOME`; do not run tests against an everyday profile.
The private website/API project is not needed to work on the browser.

The native host is in `shell/`; `beam/` contains the Elixir backend and mod runtime.
`doc/mod-api.md`, `docs/mod-ui.md`, and `brain/decisions/` describe the architecture.
When changing mod APIs, update the ModSmith guide and tool schemas in the same
change and test the behavioral contract.

Run checks relevant to your change:

```sh
swift test --package-path shell -Xswiftc -DBOWSER_COMMUNITY
(cd beam && BOWSER_HOME="$(mktemp -d /tmp/bowser-tests.XXXXXX)" mix test)
python3 -m unittest discover -s tests
```

Some native/runtime integration tests require a built release or an interactive
macOS session; consult the test's prerequisites. Keep credentials, browsing data,
screenshots containing private content, build artifacts, and local task records
out of commits. Use descriptive pull requests with validation evidence.

Mods are trusted local code with access to the user's account and pages. They
are not sandboxed extensions. Changes involving credentials, page access, native
bridges, or updates should make their trust boundaries explicit.
