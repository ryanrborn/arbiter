defmodule Arbiter.Tasks.AssigneeCompat do
  @moduledoc """
  bd-1ozks5: the local `Issue.assignee` field was removed (Arbiter is a
  single-user app; the column was unused). For one release, every surface
  that used to accept `assignee` (MCP `task_create`/`task_update`, the REST
  API, `arb create`/`arb update --assignee`) keeps accepting the key rather
  than failing an existing coordinator prompt or script, and just ignores
  it. This module is the single place that decides whether an input map
  carries the deprecated key and produces the warning text, so all of those
  surfaces say the same thing.
  """

  @warning "the `assignee` field is deprecated and ignored — Arbiter is a " <>
             "local single-user app and no longer tracks an assignee locally (bd-1ozks5)"

  @doc "The shared deprecation warning text."
  def warning, do: @warning

  @doc """
  `[warning]` if `params` carries a deprecated `assignee` key (string or
  atom), else `[]`. Meant to be appended to whatever other warnings a
  create/update call already produces.
  """
  def warnings(params) when is_map(params) do
    if Map.has_key?(params, "assignee") or Map.has_key?(params, :assignee) do
      [@warning]
    else
      []
    end
  end

  def warnings(_), do: []
end
