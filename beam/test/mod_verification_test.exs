defmodule BowserBrain.ModVerificationTest do
  use ExUnit.Case, async: false
  alias BowserBrain.ModVerification

  setup do
    previous = Application.get_env(:bowser_brain, :modsmith_verifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bowser_brain, :modsmith_verifier, previous),
        else: Application.delete_env(:bowser_brain, :modsmith_verifier)
    end)

    :ok
  end

  defp context do
    %{
      installed: true,
      documentation: false,
      requests: ["Export the selected report"],
      candidate: %{status: "active", checks: ["Button is visible"]},
      failed_attempts: [],
      last_write: 1,
      receipts: [
        %{id: 1, tool: "put_payload", result: "installed"},
        %{id: 2, tool: "page_eval", args: "fetch(reportURL)", result: "{status:403}"},
        %{id: 3, tool: "page_eval", args: "button.disabled", result: "true"}
      ]
    }
  end

  test "failed core action overrides active claim and retains proposed files for repair" do
    Application.put_env(:bowser_brain, :modsmith_verifier, fn prompt ->
      data = JSON.decode!(prompt)
      assert data["candidate"]["status"] == "active"
      assert Enum.at(data["receipts"], 1)["result"] == "{status:403}"

      {:ok,
       JSON.encode!(%{
         verified: false,
         reason: "Export failed; disabling its button does not export a report.",
         evidence: [2, 3],
         next_approach: "Investigate a supported native export library."
       })}
    end)

    assert {:error, reason} = ModVerification.assess(context())

    output =
      JSON.encode!(%{
        status: "active",
        summary: "Fixed",
        files: [%{path: "sites/example.com/export.js"}]
      })

    revised = ModVerification.partial(output, reason) |> JSON.decode!()
    assert revised["status"] == "partial"
    assert revised["files"] == [%{"path" => "sites/example.com/export.js"}]
    assert revised["next_step"] == nil
    assert revised["notes"] =~ "native export library"
  end

  test "new source and stale pre-change observations cannot be approved" do
    Application.put_env(:bowser_brain, :modsmith_verifier, fn _ ->
      flunk("no eligible evidence")
    end)

    assert {:error, _} = ModVerification.assess(%{context() | installed: false})
    assert {:error, _} = ModVerification.assess(%{context() | last_write: 3})

    assert {:error, _} =
             ModVerification.assess(%{
               context()
               | receipts: [%{id: 4, tool: "put_mod", result: "compiled"}]
             })
  end

  test "review must cite actual post-change observations and may accept a repaired failure" do
    for evidence <- [[], [1], [999]] do
      verdict = JSON.encode!(%{verified: true, reason: "Works", evidence: evidence})
      assert {:error, _} = ModVerification.verdict(verdict, [2, 3])
    end

    Application.put_env(:bowser_brain, :modsmith_verifier, fn prompt ->
      data = JSON.decode!(prompt)
      assert List.last(data["receipts"])["result"] == "Saved report exists and parses correctly"
      assert data["failed_attempts"] == [%{"reason" => "Direct request failed"}]

      {:ok,
       JSON.encode!(%{
         verified: true,
         reason: "Installed export produced the requested report",
         evidence: [5]
       })}
    end)

    repaired = %{
      context()
      | last_write: 4,
        failed_attempts: [%{reason: "Direct request failed"}],
        receipts:
          context().receipts ++
            [
              %{id: 4, tool: "put_mod", result: "installed"},
              %{
                id: 5,
                tool: "mod_diagnostics",
                result: "Saved report exists and parses correctly"
              }
            ]
    }

    assert :ok = ModVerification.assess(repaired)
  end

  test "screenshot receipts need actual post-change images for outcome review" do
    screenshot = %{id: 5, tool: "page_screenshot", result: "image metadata"}
    context = %{context() | receipts: [screenshot]}
    Application.put_env(:bowser_brain, :modsmith_verifier, fn _ ->
      {:ok, JSON.encode!(%{verified: true, reason: "Observed requested visual change", evidence: [5]})}
    end)
    assert {:error, _} = ModVerification.assess(context)
    assert :ok = ModVerification.assess(Map.put(context, :images, [%{id: 5, data: "fixture"}]))
  end

  test "unavailable and malformed reviewers leave the outcome unverified" do
    for result <- [{:error, :timeout}, {:ok, "not JSON"}, {:ok, "{}"}] do
      Application.put_env(:bowser_brain, :modsmith_verifier, fn _ -> result end)
      assert {:error, _} = ModVerification.assess(context())
    end
  end
end
