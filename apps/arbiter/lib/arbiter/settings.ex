defmodule Arbiter.Settings do
  @moduledoc """
  Singleton resource for installation-wide configuration.

  There is at most one row in `global_settings`. Use `get/0` to read it
  (creates defaults on first access) and `update_vernacular/2` /
  `update_branding/2` to write.

  Vernacular and branding both live here — not on workspaces — so all
  workspaces share a single vocabulary and a single visual identity without
  requiring per-workspace copies.
  """

  use Ash.Resource,
    domain: Arbiter.Beads,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "global_settings"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:vernacular, :branding]
    end

    update :update do
      primary? true
      accept [:vernacular, :branding]
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :vernacular, :map, default: %{}, allow_nil?: false
    attribute :branding, :map, default: %{}, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc "Fetch the singleton row, creating it with empty settings if absent."
  @spec get() :: {:ok, t()} | {:error, term()}
  def get do
    case Ash.read_one(__MODULE__, domain: Arbiter.Beads) do
      {:ok, nil} -> Ash.create(__MODULE__, %{}, domain: Arbiter.Beads)
      {:ok, settings} -> {:ok, settings}
      {:error, _} = err -> err
    end
  end

  @doc "Replace the global vernacular map."
  @spec update_vernacular(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_vernacular(settings, vernacular) when is_map(vernacular) do
    Ash.update(settings, %{vernacular: vernacular}, domain: Arbiter.Beads)
  end

  @doc "Replace the global branding map."
  @spec update_branding(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_branding(settings, branding) when is_map(branding) do
    Ash.update(settings, %{branding: branding}, domain: Arbiter.Beads)
  end
end
