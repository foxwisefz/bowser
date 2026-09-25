# AI setup

Community source builds run without account admission. Build with
`swift build --package-path shell -Xswiftc -DBOWSER_COMMUNITY`, set a separate
`BOWSER_HOME`, and run `python3 bin/configure-ai` to choose OpenAI or Anthropic.
The helper stores the credential with owner-only file permissions and does not
send a network request. Requests go directly to the selected provider.

Settings are read from `$BOWSER_HOME/settings.json` (default `~/.bowser`).
`ai_provider` selects `openai`, `anthropic`, `router`, `claude_cli`, or `hosted`.
Direct providers use their corresponding `openai_api_key` or `anthropic_api_key`;
`modsmith_model` optionally overrides the provider default. A router uses
`dodorouter_endpoint` and `dodorouter_api_key`. The explicit provider selection
takes precedence over the presence of router settings.

Hosted AI requires a valid Bowser account receipt and uses `https://api.bowser.app`
unless `BOWSER_API_ENDPOINT` overrides it. The account service and its operation
are maintained separately. Community mode does not grant hosted AI access.
Jev semantic classification currently uses the hosted service and requires an
account even when ModSmith uses a personal provider key.

Generated mods are trusted local code. API keys are stored locally, not in the
repository. Model requests may include prompts and context supplied to ModSmith.
ModSmith uses the scoped tool gateway and bounded tool loop;
`beam/priv/ai-tools.json` defines its tool catalog.
