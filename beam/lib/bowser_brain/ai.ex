defmodule BowserBrain.AI do
  @moduledoc "Direct HTTP providers and the account-authenticated Bowser AI service."
  alias BowserBrain.{Settings, Paths}

  def route(settings \\ Settings.all()) do
    provider =
      settings["ai_provider"] || if(settings["dodorouter_endpoint"], do: "router", else: "hosted")

    case provider do
      "hosted" ->
        {:responses, server(settings) <> "/v1/ai/responses", account_token(), nil}

      "openai" ->
        {:responses, "https://api.openai.com/v1/responses", settings["openai_api_key"],
         settings["modsmith_model"] || "gpt-5.4"}

      "anthropic" ->
        {:anthropic, "https://api.anthropic.com/v1/messages", settings["anthropic_api_key"],
         settings["modsmith_model"] || "claude-sonnet-4-6"}

      "router" ->
        {:responses,
         String.trim_trailing(settings["dodorouter_endpoint"] || "", "/") <> "/v1/responses",
         settings["dodorouter_api_key"], settings["modsmith_model"] || "default"}

      "claude_cli" ->
        :cli

      _ ->
        {:error, :invalid_provider}
    end
  end

  def server(settings \\ Settings.all()),
    do:
      String.trim_trailing(
        System.get_env("BOWSER_API_ENDPOINT") || settings["bowser_api_endpoint"] ||
          "https://api.bowser.app",
        "/"
      )

  def account_token do
    with {:ok, data} <- File.read(Path.join(Paths.home(), "registration.json")),
         {:ok, receipt} <- JSON.decode(data),
         token when is_binary(token) <- receipt["telemetryToken"],
         do: token,
         else: (_ -> nil)
  end

  def jev(state, questions) do
    request(server() <> "/v1/ai/jev", account_token(), %{
      "state" => state,
      "questions" => questions
    })
  end

  def request(url, key, payload, headers \\ []) do
    transport = Application.get_env(:bowser_brain, :ai_transport, &http/4)
    uri = URI.parse(url)

    local_test =
      uri.scheme == "http" && uri.host in ["127.0.0.1", "localhost", "::1"]

    cond do
      not is_binary(key) or key == "" ->
        {:error, :setup_required}

      (uri.scheme != "https" and not local_test) or uri.userinfo != nil ->
        {:error, :invalid_endpoint}

      byte_size(JSON.encode!(payload)) > 262_144 ->
        {:error, :context_too_large}

      true ->
        transport.(url, key, payload, headers)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def http(url, key, payload, extra) do
    :inets.start()
    :ssl.start()
    headers = [{~c"authorization", String.to_charlist("Bearer " <> key)} | extra]

    options = [
      # Let the server's bounded 180s generation request return its own error.
      timeout: Application.get_env(:bowser_brain, :ai_http_timeout, 195_000),
      connect_timeout: 10_000,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(payload)},
           options,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, data}} when byte_size(data) <= 2_097_152 -> JSON.decode(data)
      {:ok, {{_, status, _}, _, _}} -> {:error, status}
      {:error, :timeout} -> {:error, :timeout}
      {:error, {:timeout, _}} -> {:error, :timeout}
      _ -> {:error, :unavailable}
    end
  end

  def message(:setup_required), do: "Bowser AI access is not configured. Please check your account access."

  def message(429),
    do: "Your free AI allowance is used up. Please try again after the daily reset."

  def message(401), do: "Your AI access could not be verified. Please try again."
  def message(403), do: message(401)
  def message(:context_too_large), do: "This request is too large. Start a new mod conversation."
  def message(:timeout), do: "The AI model took too long to respond. Continue to try again; changes already made are still available."
  def message(504), do: message(:timeout)
  def message(:step_limit), do: "ModSmith reached its tool limit before finishing. Changes already made remain available to inspect or undo."
  def message(:local_agent_error), do: "ModSmith hit an internal error while processing the result. Changes already made remain available to inspect or undo."

  def message(_),
    do:
      "The AI service is unavailable. Please try again shortly."
end
