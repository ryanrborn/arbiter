defmodule ArbiterWeb.Api.PolecatController do
  @moduledoc """
  REST endpoints for polecat lifecycle. The arb CLI calls `sling/2` to
  start work on a bead; future LiveView dashboards will use the same
  endpoints + `list/2` to introspect running polecats.

  Routes:

    * `POST /api/polecats/sling`           — :sling (body: `bead_id`, optional `rig`, `with_claude`).
      Without `with_claude` the bead parks in `:in_progress` (no Driver); with
      it, a Claude subprocess works the bead and the Driver closes it on `arb done`.
    * `GET  /api/polecats`                 — :index (list active polecats)
    * `GET  /api/polecats/:bead_id`        — :show (full snapshot inc. recent output).
      When no live polecat exists for the bead, falls back to the most recent
      `Arbiter.Polecats.Run` row so finished/exited runs stay inspectable.
    * `POST /api/polecats/:bead_id/stop`   — :stop (terminate polecat cleanly)
    * `GET  /api/polecats/:bead_id/log`    — :log (full, uncapped durable
      transcript of the bead's most recent run; the audit source of record).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Polecat
  alias Arbiter.Polecat.OutputLog
  alias Arbiter.Polecat.Sling
  alias Arbiter.Polecats.Run
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  def sling(conn, params) do
    case params do
      %{"bead_id" => bead_id} when is_binary(bead_id) and bead_id != "" ->
        opts = sling_opts(params)

        case Sling.sling(bead_id, opts) do
          {:ok, result} ->
            conn
            |> put_status(:created)
            |> render(:sling, result: result)

          {:error, {:bead_not_found, _}} ->
            {:error, :not_found}

          {:error, {:bead_closed, _}} ->
            {:error,
             {:invalid_request, "bead is closed; reopen it before slinging", %{bead_id: bead_id}}}

          {:error, reason} ->
            {:error, {:server_error, "sling failed", %{reason: inspect(reason)}}}
        end

      _ ->
        {:error, {:invalid_request, "bead_id is required", %{}}}
    end
  end

  def index(conn, _params) do
    render(conn, :index, children: Polecat.list_children())
  end

  def show(conn, %{"bead_id" => bead_id}) when is_binary(bead_id) and bead_id != "" do
    case Polecat.whereis(bead_id) do
      nil ->
        show_historical(conn, bead_id)

      pid ->
        case Polecat.state(pid) do
          %{} = snap ->
            render(conn, :show, snapshot: Map.put(snap, :pid, pid))

          _ ->
            show_historical(conn, bead_id)
        end
    end
  end

  def show(_conn, _params), do: {:error, {:invalid_request, "bead_id is required", %{}}}

  # No live polecat for this bead — fall back to the most recent durable
  # `Run` row so a finished/exited run is still inspectable. 404 only when no
  # run was ever recorded.
  defp show_historical(conn, bead_id) do
    case latest_run(bead_id) do
      %Run{} = run -> render(conn, :show, run: run)
      nil -> {:error, :not_found}
    end
  end

  defp latest_run(bead_id) do
    Run
    |> Ash.Query.filter(bead_id == ^bead_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  def stop(conn, %{"bead_id" => bead_id}) when is_binary(bead_id) and bead_id != "" do
    case Polecat.stop(bead_id, :normal) do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{bead_id: bead_id, stopped: true})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def stop(_conn, _params), do: {:error, {:invalid_request, "bead_id is required", %{}}}

  # Full, uncapped durable transcript for the bead's most recent run. Resolves
  # the latest `Run` row, then reads its on-disk transcript via `OutputLog`.
  # `exists` distinguishes "no file yet / never captured" (false, lines [])
  # from "captured but empty" (true, lines []). 404 only when no run exists.
  def log(conn, %{"bead_id" => bead_id}) when is_binary(bead_id) and bead_id != "" do
    case latest_run(bead_id) do
      %Run{} = run ->
        {exists, lines} =
          case OutputLog.read_lines(run.id) do
            {:ok, lines} -> {true, lines}
            {:error, _} -> {false, []}
          end

        json(conn, %{
          data: %{
            bead_id: run.bead_id,
            run_id: run.id,
            path: OutputLog.path_for(run.id),
            exists: exists,
            line_count: length(lines),
            lines: lines
          }
        })

      nil ->
        {:error, :not_found}
    end
  end

  def log(_conn, _params), do: {:error, {:invalid_request, "bead_id is required", %{}}}

  # Map request params onto `Sling.sling/2` opts.
  #
  # Driver wiring is the important bit: the bookkeeping `Work` workflow is a
  # handful of no-op placeholder steps, so a Driver in workflow mode walks it
  # to completion in ~500ms and *closes the bead*. That's only ever correct
  # when a real worker is doing the work and will signal completion itself.
  #
  #   * `with_claude` → a Claude subprocess does the work; start the Driver in
  #     claude-driven mode (`start_claude: true` ⇒ it waits on the polecat
  #     rather than ticking the workflow to closure).
  #   * bare/dry sling → no worker. Park the bead in `:in_progress`
  #     (`start_driver: false`) for a hand to attach, instead of racing the
  #     no-op workflow to a bogus `:closed`.
  defp sling_opts(params) do
    base =
      [rig: params["rig"]]
      |> add_model_override(params["model"])

    case truthy(params["with_claude"]) do
      true -> base ++ [start_claude: true]
      _ -> base ++ [start_driver: false]
    end
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # `--model` from the CLI is forwarded into `Sling.sling/2` so the worker
  # session runs on the named model regardless of workspace/routing config.
  # Only honored when start_claude is true (no agent ⇒ no model to pick).
  defp add_model_override(opts, model) when is_binary(model) and model != "" do
    Keyword.put(opts, :model, model)
  end

  defp add_model_override(opts, _), do: opts

  defp truthy(nil), do: nil
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(false), do: false
  defp truthy("false"), do: false
  defp truthy(_), do: nil
end
