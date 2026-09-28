defmodule BowserBrain.DirectAgentTest do
  use ExUnit.Case, async: false
  alias BowserBrain.{AI, DirectAgent}

  test "HTTP deadline preserves timeout instead of reporting an unavailable service" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    previous = Application.get_env(:bowser_brain, :ai_http_timeout)
    Application.put_env(:bowser_brain, :ai_http_timeout, 50)
    worker = spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      receive do :stop -> :gen_tcp.close(socket) end
    end)
    on_exit(fn ->
      send(worker, :stop)
      :gen_tcp.close(listener)
      if previous, do: Application.put_env(:bowser_brain, :ai_http_timeout, previous),
        else: Application.delete_env(:bowser_brain, :ai_http_timeout)
    end)
    assert {:error, :timeout} = AI.http("http://127.0.0.1:#{port}/responses", "fixture", %{}, [])
    assert AI.message(:timeout) == AI.message(504)
    refute AI.message(:timeout) == AI.message(:unavailable)
  end

  test "packaged hosted catalog exposes the typed Jev tool" do
    tool = Enum.find(DirectAgent.tools(), &(&1["name"] == "jev"))
    assert tool["type"] == "function"
    assert Enum.sort(tool["parameters"]["required"]) == ["questions", "state"]
    assert tool["parameters"]["properties"]["questions"]["maxProperties"] == 16
  end

  setup do
    on_exit(fn -> Application.delete_env(:bowser_brain, :ai_transport) end)
    :ok
  end

  test "screenshots stay multimodal instead of hitting the JSON tool-size limit" do
    image = Base.encode64(:binary.copy("pixels", 20_000))
    [receipt, message] = DirectAgent.tool_output("capture-1", %{ok: true, image: image, mimeType: "image/png", width: 320})
    assert JSON.decode!(receipt["output"])["width"] == 320
    refute receipt["output"] =~ image
    assert List.last(message["content"])["image_url"] == "data:image/png;base64," <> image
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      content = List.last(body["messages"])["content"]
      assert List.last(content) == %{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/png", "data" => image}}
      {:ok, %{"content" => [%{"type" => "text", "text" => "seen"}]}}
    end)
    assert {:ok, _} = DirectAgent.completion({:anthropic, "https://api.anthropic.com/v1/messages", "key", "model"}, [message], [], "inspect")
    assert [_] = DirectAgent.tool_output("failed", %{ok: false, image: image, mimeType: "image/png"})
  end

  test "only the latest two images are replayed while earlier tool receipts remain" do
    input = Enum.flat_map(1..4, fn id -> DirectAgent.tool_output(to_string(id), %{ok: true, image: to_string(id), mimeType: "image/png"}) end)
    retained = DirectAgent.retain_images(input)
    assert Enum.count(retained, &(&1["type"] == "function_call_output")) == 4
    images = Enum.flat_map(retained, &(&1["content"] || [])) |> Enum.filter(&(&1["type"] == "input_image"))
    assert Enum.map(images, & &1["image_url"]) == ["data:image/png;base64,3", "data:image/png;base64,4"]
  end

  test "personal keys route directly and hosted is the default" do
    assert {:responses, "https://api.openai.com/v1/responses", "openai-secret", _} =
             AI.route(%{"ai_provider" => "openai", "openai_api_key" => "openai-secret"})

    assert {:anthropic, "https://api.anthropic.com/v1/messages", "claude-secret", _} =
             AI.route(%{"ai_provider" => "anthropic", "anthropic_api_key" => "claude-secret"})

    assert {:responses, "https://api.bowser.app/v1/ai/responses", _, nil} = AI.route(%{})
    assert :cli = AI.route(%{"ai_provider" => "claude_cli"})

    assert {:responses, "https://router.invalid/v1/responses", "secret", "default"} =
             AI.route(%{
               "dodorouter_endpoint" => "https://router.invalid",
               "dodorouter_api_key" => "secret"
             })
  end

  test "hosted requests cannot carry provider overrides or credential leakage" do
    Application.put_env(:bowser_brain, :ai_transport, fn url, key, body, _ ->
      assert url == "https://api.bowser.app/v1/ai/responses"
      assert key == "account-token"
      refute Map.has_key?(body, "model")
      refute JSON.encode!(body) =~ "account-token"

      {:ok,
       %{
         "output" => [
           %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "done"}]}
         ]
       }}
    end)

    assert {:ok, [_]} =
             DirectAgent.completion(
               {:responses, "https://api.bowser.app/v1/ai/responses", "account-token", nil},
               [%{"role" => "user", "content" => "hello"}],
               [],
               "system"
             )
  end

  test "router nested tool calls become replayable Responses function calls" do
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, _ ->
      case body["input"] do
        [] ->
          {:ok,
           %{
             "output" => [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_call",
                     "call_id" => "call-1",
                     "name" => "list_tabs",
                     "arguments" => "{}"
                   }
                 ]
               }
             ]
           }}

        [call, result] ->
          assert call == %{
                   "type" => "function_call",
                   "call_id" => "call-1",
                   "name" => "list_tabs",
                   "arguments" => "{}"
                 }

          assert result["call_id"] == call["call_id"]

          {:ok,
           %{
             "output" => [
               %{
                 "type" => "message",
                 "content" => [
                   %{"type" => "output_text", "text" => "done"}
                 ]
               }
             ]
           }}
      end
    end)

    route = {:responses, "https://router.invalid/v1/responses", "key", "default"}
    assert {:ok, [call]} = DirectAgent.completion(route, [], [], "system")
    result = %{"type" => "function_call_output", "call_id" => "call-1", "output" => "[]"}

    assert {:ok, [%{"type" => "message"}]} =
             DirectAgent.completion(route, [call, result], [], "system")
  end

  test "Anthropic tool calls round trip with matched tool results" do
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, body, headers ->
      assert {~c"anthropic-version", ~c"2023-06-01"} in headers

      assert Enum.at(body["messages"], 1)["content"] == [
               %{"type" => "tool_use", "id" => "call-1", "name" => "list_tabs", "input" => %{}}
             ]

      assert Enum.at(body["messages"], 2)["content"] == [
               %{"type" => "tool_result", "tool_use_id" => "call-1", "content" => "{}"}
             ]

      {:ok, %{"content" => [%{"type" => "text", "text" => "done"}]}}
    end)

    input = [
      %{"role" => "user", "content" => "hello"},
      %{
        "type" => "function_call",
        "call_id" => "call-1",
        "name" => "list_tabs",
        "arguments" => "{}"
      },
      %{"type" => "function_call_output", "call_id" => "call-1", "output" => "{}"}
    ]

    assert {:ok, [%{"type" => "message"}]} =
             DirectAgent.completion(
               {:anthropic, "https://api.anthropic.com/v1/messages", "key", "model"},
               input,
               [],
               "system"
             )
  end

  test "local hosted API permits loopback HTTP without permitting remote plaintext" do
    Application.put_env(:bowser_brain, :ai_transport, fn url, _, _, _ -> {:ok, url} end)

    for host <- ["127.0.0.1", "localhost", "[::1]"] do
      url = "http://#{host}:8080/v1/ai/responses"
      assert {:ok, ^url} = AI.request(url, "local-account", %{})
    end

    assert {:error, :invalid_endpoint} = AI.request("ftp://localhost/file", "key", %{})
    assert {:error, :invalid_endpoint} = AI.request("http://localhost.example.com", "key", %{})
  end

  test "missing credentials and insecure endpoints fail before transport" do
    Application.put_env(:bowser_brain, :ai_transport, fn _, _, _, _ -> flunk("must not send") end)
    assert {:error, :setup_required} = AI.request("https://api.bowser.app", nil, %{})
    assert {:error, :invalid_endpoint} = AI.request("http://remote.invalid", "key", %{})

    assert {:error, :invalid_endpoint} =
             AI.request("https://user:pass@remote.invalid", "key", %{})
  end
end
