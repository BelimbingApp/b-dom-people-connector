defmodule Bilimbi.PeopleConnector.Connector.MigrationVersionsTest do
  use ExUnit.Case, async: true

  @apps Path.expand("../../../..", __DIR__)
  @own Path.expand("../priv/repo/migrations", __DIR__)

  defp versions(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Map.new(fn file ->
      {version, _} = Integer.parse(Path.basename(file))
      {version, file}
    end)
  end

  test "connector migration versions do not collide with other mounted modules" do
    own = versions(@own)

    others =
      @apps
      |> Path.join("**/priv/repo/migrations")
      |> Path.wildcard()
      |> Enum.reject(&(Path.expand(&1) == @own))
      |> Enum.flat_map(&Map.to_list(versions(&1)))

    collisions =
      for {version, file} <- others, Map.has_key?(own, version) do
        "#{version}: #{Path.relative_to(file, @apps)} vs #{Path.relative_to(own[version], @apps)}"
      end

    assert collisions == []
  end
end
