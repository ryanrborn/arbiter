defmodule Arbiter.Tasks.DoltImport.Mapper do
  @moduledoc """
  Pure field-mapping functions for the Dolt-to-Postgres import task.

  Separated from the mix task so we can unit-test the conversions without
  needing a live Dolt DB.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Dependency

  @valid_dep_types Dependency
                   |> then(fn _ ->
                     [:blocks, :depends_on, :relates_to, :discovered_from, :parent_of]
                   end)

  @doc "Map a Dolt `status` string to an Ash Issue status atom."
  def map_status("open"), do: :open
  def map_status("closed"), do: :closed
  def map_status(_), do: :in_progress

  @doc "Map a Dolt `issue_type` string to an Ash Issue issue_type atom, defaulting to :task for unknown values."
  def map_issue_type(t) when is_binary(t) do
    valid = Issue.issue_types() |> Enum.map(&Atom.to_string/1)

    if t in valid do
      String.to_existing_atom(t)
    else
      :task
    end
  end

  def map_issue_type(_), do: :task

  @doc "Clamp / default priority to the [0, 4] range. Default 2."
  def parse_priority(p) when is_integer(p) and p in 0..4, do: p
  def parse_priority(p) when is_integer(p) and p > 4, do: 4
  def parse_priority(p) when is_integer(p) and p < 0, do: 0
  def parse_priority(_), do: 2

  @doc """
  Parse a Dolt `external_ref` like `"jira-VR-17585"` into a
  `{tracker_type, tracker_ref}` tuple.

  Returns `{:none, nil}` for missing / empty / unknown formats.
  """
  def parse_external_ref(nil), do: {:none, nil}
  def parse_external_ref(""), do: {:none, nil}

  def parse_external_ref(ref) when is_binary(ref) do
    case String.split(ref, "-", parts: 2) do
      ["jira", id] -> {:jira, id}
      ["linear", id] -> {:linear, id}
      ["gh", id] -> {:github, id}
      ["github", id] -> {:github, id}
      _ -> {:none, nil}
    end
  end

  @doc "Map a Dolt dependency type string (e.g. \"discovered-from\") to an Ash atom, or nil if unrecognized."
  def map_dep_type(s) when is_binary(s) do
    normalized = s |> String.replace("-", "_") |> String.downcase()

    Enum.find(@valid_dep_types, fn t -> Atom.to_string(t) == normalized end)
  end

  def map_dep_type(_), do: nil

  @doc "Convert nil and \"\" to nil; pass other strings through."
  def nonempty(nil), do: nil
  def nonempty(""), do: nil
  def nonempty(s) when is_binary(s), do: s
  def nonempty(_), do: nil

  @doc """
  Parse a Dolt-formatted datetime string (`"2026-05-19 19:21:46.123456"`) to a
  `DateTime` in UTC. Returns `nil` for nil / empty / unparseable inputs.
  """
  def parse_dt(nil), do: nil
  def parse_dt(""), do: nil

  def parse_dt(s) when is_binary(s) do
    iso = String.replace(s, " ", "T") <> "Z"

    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  def parse_dt(_), do: nil

  @doc """
  Compose the final `description` from Dolt's `description` and `design` fields.
  If `design` is non-empty, append it as a `## Design` section.
  """
  def compose_description(row) when is_map(row) do
    desc = Map.get(row, "description") || ""
    design = Map.get(row, "design") || ""

    cond do
      design == "" -> desc
      desc == "" -> "## Design\n\n#{design}"
      true -> "#{desc}\n\n## Design\n\n#{design}"
    end
  end

  @doc """
  Derive a workspace prefix from a list of Dolt issue rows by taking the prefix
  of the first row's id (e.g. \"hq-3o8\" → `\"hq\"`).
  """
  def derive_prefix([%{"id" => id} | _]) when is_binary(id) do
    id |> String.split("-", parts: 2) |> List.first() |> String.downcase()
  end

  def derive_prefix(_), do: "bd"
end
