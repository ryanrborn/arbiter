defmodule ArbiterWeb.Api.RunJSON do
  @moduledoc """
  Render functions for `Arbiter.Polecats.Run`.

  `:index` omits `output_lines` (which can be up to 500 strings) to keep list
  responses compact — clients fetch full output through `:show`.
  """

  alias Arbiter.Polecats.Run

  def index(%{runs: runs}) do
    %{data: Enum.map(runs, &summary/1)}
  end

  def show(%{run: run}), do: %{data: detail(run)}

  defp summary(%Run{} = r) do
    %{
      id: r.id,
      bead_id: r.bead_id,
      bead_title: r.bead_title,
      repo: r.repo,
      workspace_id: r.workspace_id,
      status: to_string_atom(r.status),
      started_at: iso(r.started_at),
      completed_at: iso(r.completed_at),
      exit_code: r.exit_code,
      failure_reason: r.failure_reason
    }
  end

  defp detail(%Run{} = r) do
    summary(r)
    |> Map.merge(%{
      output_lines: r.output_lines || [],
      inserted_at: iso(r.inserted_at),
      updated_at: iso(r.updated_at)
    })
  end

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
