defmodule Arbiter.Settings do
  @moduledoc """
  Singleton resource for installation-wide configuration.

  There is at most one row in `global_settings`. Use `get/0` to read it
  (creates defaults on first access) and `update_vernacular/1` to write.

  Vernacular lives here — not on workspaces — so all workspaces share a
  single vocabulary without requiring per-workspace copies.
  """

  use Ash.Resource,
    domain: Arbiter.Beads,
    data_layer: AshPostgres.DataLayer

  attributes do
    uuid_primary_key(:id)
    attribute(:vernacular, :map, default: %{}, allow_nil?: false)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:vernacular])
    end

    update :update do
      primary?(true)
      accept([:vernacular])
      require_atomic?(false)
    end
  end

  postgres do
    table("global_settings")
    repo(Arbiter.Repo)
  end

  @doc "Fetch the singleton row, creating it with empty vernacular if absent."
  @spec get() :: {:ok, t()} | {:error, term()}
  def get do
    case Ash.read_one(__MODULE__, domain: Arbiter.Beads) do
      {:ok, nil} -> Ash.create(__MODULE__, %{vernacular: %{}}, domain: Arbiter.Beads)
      {:ok, settings} -> {:ok, settings}
      {:error, _} = err -> err
    end
  end

  @doc "Replace the global vernacular map."
  @spec update_vernacular(map(), map()) :: {:ok, map()} | {:error, term()}
  def update_vernacular(settings, vernacular) when is_map(vernacular) do
    Ash.update(settings, %{vernacular: vernacular}, domain: Arbiter.Beads)
  end
end
