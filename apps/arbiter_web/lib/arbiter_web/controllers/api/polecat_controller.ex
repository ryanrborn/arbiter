defmodule ArbiterWeb.Api.PolecatController do
  @moduledoc """
  REST endpoints for polecat lifecycle. The arb CLI calls `sling/2` to
  start work on a bead; future LiveView dashboards will use the same
  endpoints + `list/2` to introspect running polecats.

  Routes:

    * `POST /api/polecats/sling`           — :sling (body: `bead_id`, optional `rig`, `with_claude`).
      Without `with_claude` the bead parks in `:in_progress` (no Driver); with
      it, a Claude subprocess works the bead and the Driver closes it on `arb done`.
    * `POST /api/polecats/review`          — :review (body: `bead_id`, optional `rig`).
      Dispatches a review-only acolyte: no worktree, no per-bead branch, no
      route through the Crucible/merger. Always claude-driven.
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

          {:error, :no_rig_configured} ->
            {:error,
             {:invalid_request,
              "no rigs configured — add at least one rig to your workspace config " <>
                "(rig_paths) or application env (:arbiter, :rig_paths), " <>
                "or pass a rig explicitly: `arb sling #{bead_id} <rig>`",
              %{bead_id: bead_id}}}

          {:error, {:rig_not_found, rig}} ->
            {:error,
             {:invalid_request,
              "rig #{inspect(rig)} is not in :rig_paths — check your workspace config or " <>
                "application env (:arbiter, :rig_paths)",
              %{bead_id: bead_id, rig: rig}}}

          {:error, {:ambiguous_rig, rigs}} ->
            {:error,
             {:invalid_request,
              "multiple rigs available (#{Enum.join(rigs, ", ")}) — specify one: " <>
                "`arb sling #{bead_id} <rig>`",
              %{bead_id: bead_id, available_rigs: rigs}}}

          {:error, reason} ->
            {:error, {:server_error, "sling failed", %{reason: inspect(reason)}}}
        end

      _ ->
        {:error, {:invalid_request, "bead_id is required", %{}}}
    end
  end

  @doc """
  Dispatch a review-only directive. The bead is slung with `review: true`,
  which forces the `CodeReview` workflow, skips worktree provisioning, swaps
  the work prompt for the review prompt, and tags the polecat as
  `review_only` so completion does not fan out to the Crucible/merger.

  Always claude-driven (`start_claude: true`) — a review without an agent has
  nothing to do.
  """
  def review(conn, params) do
    case params do
      %{"bead_id" => bead_id} when is_binary(bead_id) and bead_id != "" ->
        opts = review_opts(params)

        case Sling.sling(bead_id, opts) do
          {:ok, result} ->
            conn
            |> put_status(:created)
            |> render(:sling, result: result)

          {:error, {:bead_not_found, _}} ->
            {:error, :not_found}

          {:error, {:bead_closed, _}} ->
            {:error,
             {:invalid_request, "bead is closed; reopen it before reviewing", %{bead_id: bead_id}}}

          {:error, reason} ->
            {:error, {:server_error, "review dispatch failed", %{reason: inspect(reason)}}}
        end

      _ ->
        {:error, {:invalid_request, "bead_id is required", %{}}}
    end
  end

  @doc """
  Resume a stopped acolyte (bd-auma3z). Re-attaches a fresh agent to the bead's
  preserved outpost worktree with a git-derived briefing of the prior run's
  work, so it continues rather than restarting from scratch. Always
  claude-driven. Renders the same payload as `sling/2`.
  """
  def resume(conn, %{"bead_id" => bead_id} = params)
      when is_binary(bead_id) and bead_id != "" do
    opts = resume_opts(params)

    case Sling.resume(bead_id, opts) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> render(:sling, result: result)

      {:error, {:bead_not_found, _}} ->
        {:error, :not_found}

      {:error, {:bead_closed, _}} ->
        {:error,
         {:invalid_request, "bead is closed; reopen it before resuming", %{bead_id: bead_id}}}

      {:error, :no_outpost} ->
        {:error,
         {:invalid_request,
          "no preserved outpost worktree for this bead — nothing to resume; sling it fresh instead",
          %{bead_id: bead_id}}}

      {:error, :rig_unknown} ->
        {:error,
         {:invalid_request,
          "could not resolve the rig for this bead; pass it explicitly: `arb resume <bead> <rig>`",
          %{bead_id: bead_id}}}

      {:error, {:acolyte_active, status}} ->
        {:error,
         {:invalid_request,
          "an acolyte is still active for this bead (#{status}); stop it before resuming",
          %{bead_id: bead_id}}}

      {:error, reason} ->
        {:error, {:server_error, "resume failed", %{reason: inspect(reason)}}}
    end
  end

  def resume(_conn, _params), do: {:error, {:invalid_request, "bead_id is required", %{}}}

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

  # Map request params onto `Sling.resume/2` opts. Rig is optional — resume
  # falls back to the bead's most recent run's rig when omitted. `--model` is an
  # optional per-dispatch override, same as sling.
  defp resume_opts(params) do
    [rig: params["rig"]]
    |> add_model_override(params["model"])
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # `--model` from the CLI is forwarded into `Sling.sling/2` so the worker
  # session runs on the named model regardless of workspace/routing config.
  # Only honored when start_claude is true (no agent ⇒ no model to pick).
  defp add_model_override(opts, model) when is_binary(model) and model != "" do
    Keyword.put(opts, :model, model)
  end

  defp add_model_override(opts, _), do: opts

  # Review-only dispatch. `review: true` cascades into Sling: it pulls the
  # CodeReview workflow, suppresses worktree provisioning, swaps the prompt,
  # and stamps `review_only` into the polecat's meta so completion doesn't
  # fan out to the Crucible.
  #
  # `with_claude` defaults to true — a reviewer with no agent has nothing to
  # do. Tests pass `with_claude: false` to dispatch a review without spawning
  # a Claude subprocess.
  defp review_opts(params) do
    base = [rig: params["rig"], review: true]

    start_claude =
      case truthy(params["with_claude"]) do
        false -> false
        _ -> true
      end

    base
    |> Keyword.put(:start_claude, start_claude)
    |> Keyword.put(:start_driver, false)
    |> add_model_override(params["model"])
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp truthy(nil), do: nil
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(false), do: false
  defp truthy("false"), do: false
  defp truthy(_), do: nil
end
