# Script for populating the database. Run via:
#
#     mix run apps/arbiter/priv/repo/seeds.exs
#
# (or automatically as part of `mix ecto.setup` via the aliases in mix.exs)
#
# Idempotent — re-running won't duplicate.

require Ash.Query

alias Arbiter.Tasks.Workspace

default_name = "default"

existing =
  Workspace
  |> Ash.Query.filter(name == ^default_name)
  |> Ash.read_one!()

case existing do
  nil ->
    {:ok, _ws} =
      Ash.create(Workspace, %{
        name: default_name,
        description: "Default workspace shipped at boot. No external tracker.",
        config: %{
          "tracker" => %{"type" => "none"}
        }
      })

    IO.puts("✓ Seeded default workspace")

  %Workspace{} ->
    IO.puts("• Default workspace already exists; skipping")
end
