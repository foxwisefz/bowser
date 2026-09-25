defmodule BowserBrain.QualityFilterTest do
  use ExUnit.Case, async: true
  alias BowserBrain.{QualityFilter, Jev}

  test "only strong filler and low usefulness judgments hide content" do
    for {filler, useful, expected} <- [
          {0.99, 0.02, true},
          {0.9, 0.02, false},
          {0.99, 0.5, false},
          {1.1, 0.02, false},
          {0.99, -1, false},
          {nil, 0.02, false}
        ] do
      assert QualityFilter.hide?(
               %{"filler_0" => %{"noul" => filler}, "useful_0" => %{"noul" => useful}},
               0
             ) == expected
    end

    refute QualityFilter.hide?(%{}, 0)
  end

  test "each item gets independent quality and usefulness questions" do
    for mode <- ["x", "amazon"] do
      questions = QualityFilter.questions(mode, [%{"id" => "1"}, %{"id" => "2"}])
      assert map_size(questions) == 4
      assert questions["filler_1"]["type"] == "noul"
      assert questions["useful_1"]["instructions"] =~ "items[1].text"
    end
  end

  test "Jev rejects oversized requests before transport" do
    assert {:error, :request_too_large} =
             Jev.evaluate(String.duplicate("x", 33000), %{"a" => %{}})

    assert {:error, :request_too_large} = Jev.evaluate("hello", %{})
    assert {:error, :invalid_request} = Jev.evaluate("hello", [])
  end

  test "sample modules compile with their explicit host scope" do
    for {file, module, host} <- [
          {"x_quality_filter.ex", XQualityFilter, "x.com"},
          {"amazon_quality_filter.ex", AmazonQualityFilter, "amazon.com"}
        ] do
      Code.compile_file(Path.expand("../example_mods/" <> file, __DIR__))
      assert module.__bowser_host__() == host
    end
  end
end
