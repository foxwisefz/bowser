defmodule BowserBrain.ModSmithLearnScopeTest do
  use ExUnit.Case, async: true
  alias BowserBrain.ModSmith

  test "browser derives exact exercise boundaries from its configured service" do
    service = "http://127.0.0.1:8080"
    for exercise <- ["slopshop", "slopyapper", "quiet"] do
      assert ModSmith.learn_scope(service <> "/learn/" <> exercise, service) == %{
        path: "/learn/" <> exercise, selector: "[data-demo-site=\"#{exercise}\"]"}
    end
    for url <- ["https://other.test/learn/slopshop", "http://127.0.0.1:9090/learn/slopshop", "http://user@127.0.0.1:8080/learn/slopshop", service <> "/shop", service <> "/learn/slopshop/other"] do
      assert ModSmith.learn_scope(url, service) == nil
    end
  end
end
