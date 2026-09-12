defmodule Arbiter.Agents.Preflight do
  @moduledoc """
  Cheap, provider-agnostic auth pre-flight for the agent CLI (bd-awi4nw).

  The confirmed failure mode: the operator's Claude OAuth (or Gemini key)
  expires, every worker spawn 401s, and the fleet burns cycles dispatching a
  wave of workers that all fail with a buried generic error. The fix is to
  *probe before dispatching*: run a single cheap `claude --print` (or
  `gemini -p`) round-trip and check it authenticates. If it doesn't, refuse to
  dispatch and tell the operator to re-authenticate.

  This module owns the **probe execution**: it spawns the adapter's probe argv
  through an Erlang `Port` (the same liveness-first mechanism the worker uses
  for real workers), captures output + exit status under a timeout, and hands
  the result to `Arbiter.Worker.StopReason` for classification. The adapter
  supplies *what* to run via the optional `auth_probe_argv/1` callback; an
  adapter that doesn't implement it is unprobeable and `check/2` returns
  `:skipped` (we never block on an absent probe).

  ## Result

    * `:ok` — the probe authenticated and exited cleanly.
    * `{:error, %StopReason{}}` — the probe failed; the reason carries the
      classified cause (`:auth_expired`, `:credit_exhausted`, …) + remediation.
    * `:skipped` — the adapter exposes no probe, so there's nothing to check.

  ## The spend this costs (bd-adyhvn)

  A pre-flight is not free: it runs per dispatch *and* per resume, and a
  one-word prompt still ships the CLI's whole system prompt and tool
  definitions (~39K cache-read tokens a call, measured). Every probe that
  actually spawns therefore writes one `usage_events` row with
  `source: :preflight` via `Arbiter.Usage.Probe` — carrying real token counts
  when the CLI returned a structured result, and an explained null cost when
  it didn't. The ledger write is best-effort and never changes the verdict.

  A `:skipped` (adapter has no probe) or an un-runnable probe (CLI missing)
  writes nothing: no process ran, so nothing was spent.

  ## Test injection

  Pass `:probe_command` (an argv list) to bypass the adapter and run an
  arbitrary script — tests use this to simulate a 401 / a clean ping without a
  real CLI. `:probe_env` overrides the spawn env; `:timeout_ms` overrides the
  default wait.
  """

  require Logger

  alias Arbiter.Usage
  alias Arbiter.Worker.StopReason

  @default_timeout_ms 30_000

  @type result :: :ok | {:error, StopReason.t()} | :skipped

  @doc """
  Run the auth pre-flight for `adapter`.

  `opts`:
    * `:probe_command` — argv override (tests); bypasses the adapter.
    * `:probe_env` — env override (`[{name, value}]`); defaults to the
      adapter's `spawn_env/1` so the probe authenticates exactly as a real
      worker spawn would.
    * `:timeout_ms` — max wait before declaring the probe hung (default 30s).
    * `:usage_task_id` — the task this check is gating, when there is one.
      Recorded on the ledger row (bd-adyhvn).
    * `:usage_workspace_id` — workspace to attribute the spend to; defaults to
      the id of the `:workspace` opt when one is threaded through.
    * any keys the adapter's `auth_probe_argv/1` / `spawn_env/1` read
      (`:api_key`, `:model`, …).
  """
  @spec check(module(), keyword()) :: result()
  def check(adapter, opts \\ []) when is_atom(adapter) and is_list(opts) do
    case resolve_argv(adapter, opts) do
      {:ok, argv} -> run(adapter, argv, opts)
      :skipped -> :skipped
      {:error, reason} -> {:error, probe_unavailable(reason)}
    end
  end

  # ---- argv resolution ---------------------------------------------------

  defp resolve_argv(adapter, opts) do
    case Keyword.get(opts, :probe_command) do
      [exec | _] = argv when is_binary(exec) ->
        {:ok, argv}

      _ ->
        adapter_argv(adapter, opts)
    end
  end

  defp adapter_argv(adapter, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :auth_probe_argv, 1) do
      adapter.auth_probe_argv(opts)
    else
      :skipped
    end
  end

  # ---- probe execution ---------------------------------------------------

  defp run(adapter, [exec | _] = argv, opts) do
    case resolve_executable(exec) do
      {:ok, resolved} ->
        env = Keyword.get(opts, :probe_env) || safe_spawn_env(adapter, opts)
        timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        spawn_and_classify(resolved, argv, env, timeout, adapter, opts)

      {:error, reason} ->
        {:error, probe_unavailable(reason)}
    end
  end

  defp spawn_and_classify(resolved, [_ | rest], env, timeout, adapter, opts) do
    port =
      Port.open(
        {:spawn_executable, resolved},
        [
          {:args, rest},
          {:line, 65_536},
          :binary,
          :exit_status,
          :stderr_to_stdout
        ] ++ env_opt(env)
      )

    started_at = System.monotonic_time(:millisecond)
    {status, lines} = collect(port, timeout, [])

    # bd-adyhvn: the process ran, so it spent — split the CLI's structured
    # result out of the output *before* classifying (its integers would
    # otherwise read as provider-error signatures) and record the draw.
    {usage, diagnostic_lines} = Usage.Probe.parse(lines)
    record_usage(adapter, usage, status, opts, System.monotonic_time(:millisecond) - started_at)

    verdict(status, diagnostic_lines)
  rescue
    e -> {:error, probe_unavailable(Exception.message(e))}
  end

  # Accumulate output lines (oldest-first) until the port exits or we time out.
  # Returns `{exit_status_or_nil, lines}`; classification happens in
  # `verdict/2` once the structured usage payload has been split off.
  defp collect(port, timeout, acc) do
    receive do
      {^port, {:data, {:eol, line}}} -> collect(port, timeout, [line | acc])
      {^port, {:data, {:noeol, line}}} -> collect(port, timeout, [line | acc])
      {^port, {:exit_status, status}} -> {status, Enum.reverse(acc)}
    after
      timeout ->
        safe_close(port)
        {nil, Enum.reverse(acc)}
    end
  end

  # A clean exit usually means auth is fine — but a CLI can print an auth/credit
  # error and still exit 0, so we run the output through the classifier and only
  # accept when it sees no failure signature.
  defp verdict(0, lines) do
    reason = StopReason.classify(0, lines)

    case reason.category do
      :exited_without_done -> :ok
      # bd-606zlr: also a clean exit with no failure signature — the probe's
      # auth verdict must not flip just because its output happened to refine
      # into the async-wait category.
      :async_wait_abandoned -> :ok
      _ -> {:error, reason}
    end
  end

  defp verdict(status, lines), do: {:error, StopReason.classify(status, lines)}

  defp record_usage(adapter, usage, status, opts, elapsed_ms) do
    Usage.Probe.record(:preflight, usage,
      task_id: Keyword.get(opts, :usage_task_id),
      workspace_id: usage_workspace_id(opts),
      provider: safe_provider(adapter),
      exit_status: status,
      duration_ms: elapsed_ms
    )

    :ok
  end

  defp usage_workspace_id(opts) do
    case Keyword.get(opts, :usage_workspace_id) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case Keyword.get(opts, :workspace) do
          %{id: id} when is_binary(id) -> id
          _ -> nil
        end
    end
  end

  defp safe_provider(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :provider, 0) do
      adapter.provider()
    end
  rescue
    _ -> nil
  end

  # ---- helpers -----------------------------------------------------------

  defp resolve_executable(exec) do
    cond do
      String.contains?(exec, "/") and File.exists?(exec) -> {:ok, exec}
      String.contains?(exec, "/") -> {:error, {:executable_not_found, exec}}
      true -> find_on_path(exec)
    end
  end

  defp find_on_path(exec) do
    case System.find_executable(exec) do
      nil -> {:error, {:executable_not_found, exec}}
      path -> {:ok, path}
    end
  end

  defp safe_spawn_env(adapter, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(opts)
    else
      []
    end
  end

  defp env_opt([]), do: []
  defp env_opt(pairs), do: [{:env, env_charlists(pairs)}]

  defp env_charlists(pairs) do
    Enum.map(pairs, fn
      {name, false} -> {to_charlist(name), false}
      {name, value} when is_binary(value) -> {to_charlist(name), to_charlist(value)}
    end)
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # The probe couldn't even run (CLI missing, spawn failed). That's still a
  # refuse-to-dispatch condition — dispatching would fail the same way — but it's a
  # crash/setup issue, not credential expiry, so classify it as such.
  defp probe_unavailable({:executable_not_found, exec}) do
    %StopReason{
      category: :crashed,
      summary: "agent CLI not found on PATH (#{exec})",
      remediation: "Install / fix the agent CLI on the host before dispatching.",
      exit_status: nil,
      signal: nil
    }
  end

  defp probe_unavailable(reason) do
    %StopReason{
      category: :crashed,
      summary: "agent auth pre-flight could not run: #{inspect(reason)}",
      remediation: "Check the agent CLI install + host before dispatching.",
      exit_status: nil,
      signal: nil
    }
  end
end
