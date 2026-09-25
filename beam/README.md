# bowser_brain — the BEAM brain

Every mod is a supervised OTP process; code hot-swaps into the running
browser. See `brain/decisions/0002` and `0007`.

## Run from source

Follow the repository [build instructions](../README.md#build-from-source).
Use `BOWSER_HOME` to isolate development data. Community builds do not require
the private server. ModSmith supports direct OpenAI and Anthropic providers;
`python3 bin/configure-ai` from the repository root stores a key in the selected
profile without placing it in terminal history. Hosted AI requires a Bowser
account. Settings live in `$BOWSER_HOME/settings.json` (default `~/.bowser`).

## Mods

Live in `~/.bowser/mods/*.ex`. Drop a file in → running in <1s. Edit → the
process hot-swaps on its next event, state intact. Break it → compile error
logged, old code keeps running. Try `example_mods/hello.ex`:

```sh
cp example_mods/hello.ex ~/.bowser/mods/
```

From iex, drive the browser directly:

```elixir
BowserBrain.Browser.navigate("https://servo.org")
BowserBrain.Browser.eval_js("document.title")
```
