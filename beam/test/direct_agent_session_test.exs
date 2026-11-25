defmodule BowserBrain.DirectAgentSessionTest do
  use ExUnit.Case, async: true
  alias BowserBrain.DirectAgentSession

  test "checkpoints retain recent work within a fixed byte and entry budget" do
    session = Enum.reduce(1..200, DirectAgentSession.restore(nil), fn n, session ->
      DirectAgentSession.record(session, %{"type" => "tool", "name" => "read_mod",
        "result" => DirectAgentSession.excerpt(String.duplicate("界", 20_000)), "sequence" => n})
    end)
    assert byte_size(JSON.encode!(session)) <= 262_144
    assert length(session["entries"]) <= 96
    assert session["omitted"]
    assert List.last(session["entries"])["sequence"] == 200
    assert session == session |> JSON.encode!() |> JSON.decode!() |> DirectAgentSession.restore()
    assert DirectAgentSession.restore("cli-session")["entries"] == []
    assert DirectAgentSession.restore(%{"version" => 99})["entries"] == []
  end

  test "an interrupted operation stays pending until its result is recorded" do
    pending = %{"type" => "tool", "name" => "put_payload", "status" => "pending"}
    session = DirectAgentSession.restore(nil) |> DirectAgentSession.record(pending)
    assert session["entries"] == [pending]
    done = Map.merge(pending, %{"status" => "returned", "result" => "installed"})
    assert DirectAgentSession.record(session, done, true)["entries"] == [done]
  end
end
