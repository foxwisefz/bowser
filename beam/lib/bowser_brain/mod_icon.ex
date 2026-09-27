defmodule BowserBrain.ModIcon do
  @moduledoc "Profile-local website icons for mod management, reusing the browser cache."

  def cached(url, profile) when is_binary(url) do
    uri = URI.parse(if String.contains?(url, "://"), do: url, else: "https://" <> url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      [URI.to_string(uri), "https://#{uri.host}", "http://#{uri.host}"]
      |> Enum.uniq()
      |> Enum.find_value(fn candidate ->
        path = Path.join([BowserBrain.Paths.home(), "app-icons-v2",
          BowserBrain.IconJobs.icon_key(candidate, profile) <> ".png"])
        if File.regular?(path), do: path
      end)
    end
  end
  def cached(_, _), do: nil
end
