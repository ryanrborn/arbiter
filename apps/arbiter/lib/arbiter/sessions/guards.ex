defmodule Arbiter.Sessions.Guards do
  @moduledoc """
  The two blast-radius guards RFC §10.1 leaves for phase 1 (bd-bpt0ag).

  Both are pure predicates, so they can be asserted directly and reused from
  whichever surface grows the calling endpoint later.

  ## Self-kill — enforced here, now

  A session must not be able to terminate **its own** scope through Arbiter's
  API: the call would kill the caller mid-call, so the operator gets no answer
  and the row never records why it died. `check_self_kill/2` is wired into
  `Arbiter.Sessions.kill/2`; the operator kills a session from the dashboard or
  the CLI, where there is no caller session to destroy.

  A session identifies itself by the `ARB_SESSION_ID` its scope exports
  (`Arbiter.Sessions.Provider.ClaudeCode.env/1`), which an API/MCP caller
  forwards as `:caller_session_id`. A *missing* caller id means "not from
  inside a session" and is allowed — that is the operator path, and defaulting
  the other way would lock the dashboard out of killing anything.

  ## Restart rate limit — the hook, per §10.1

  The other §10.1 guard is restart recursion: a session that restarts arbiter
  on a crash-loop can wedge the fleet, so the rule is "refuse more than N
  restarts per window from session-origin callers, and surface it rather than
  failing silently". Phase 1 does not own a restart endpoint — there is no
  caller yet — so what lands here is the decision itself, as a pure function
  over the caller's recent restart timestamps: `check_restart_budget/2`.

  Whichever phase adds the endpoint supplies the history (the `sessions` row's
  own audit trail, or the event log) and gets the refusal message for free.
  Keeping the *policy* here, rather than deferring it wholesale, is what stops
  the endpoint from shipping with no limit at all.
  """

  require Logger

  @default_restart_limit 3
  @default_restart_window_seconds 600

  @doc """
  Refuse a kill that targets the caller's own session (§10.1).

  Returns `:ok`, or `{:error, {:self_kill, message}}` with a message naming the
  session and the way out. Comparison is trimmed and case-insensitive so a
  header or env var that picked up whitespace cannot walk around the guard.
  """
  @spec check_self_kill(String.t(), String.t() | nil) :: :ok | {:error, {:self_kill, String.t()}}
  def check_self_kill(target_id, caller_session_id)

  def check_self_kill(target_id, nil) when is_binary(target_id), do: :ok

  def check_self_kill(target_id, caller_session_id)
      when is_binary(target_id) and is_binary(caller_session_id) do
    if normalize(target_id) == normalize(caller_session_id) do
      {:error,
       {:self_kill,
        "session #{target_id} cannot kill its own session through Arbiter's API — " <>
          "the call would terminate the caller mid-call. Kill it from the dashboard " <>
          "or the CLI instead (§10.1)."}}
    else
      :ok
    end
  end

  @doc """
  Rate-limit server restarts requested from inside a session (§10.1 hook).

  `recent_restarts` is the caller's restart timestamps, newest or oldest first
  — order does not matter. `nil` means the request did not come from a session
  (the operator path) and is never limited.

  ## Options

    * `:limit` — restarts allowed in the window (default #{@default_restart_limit}).
    * `:window_seconds` — the window (default #{@default_restart_window_seconds}).
    * `:now` — clock injection for tests.
  """
  @spec check_restart_budget([DateTime.t()] | nil, keyword()) ::
          :ok | {:error, {:restart_rate_limited, String.t()}}
  def check_restart_budget(recent_restarts, opts \\ [])

  def check_restart_budget(nil, _opts), do: :ok

  def check_restart_budget(recent_restarts, opts) when is_list(recent_restarts) do
    limit = Keyword.get(opts, :limit, @default_restart_limit)
    window = Keyword.get(opts, :window_seconds, @default_restart_window_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -window, :second)

    in_window = Enum.count(recent_restarts, &(DateTime.compare(&1, cutoff) != :lt))

    if in_window >= limit do
      message =
        "refusing to restart arbiter: #{in_window} restart(s) already requested from this " <>
          "session in the last #{window}s, limit is #{limit} (§10.1 restart recursion)"

      Logger.warning(message)
      {:error, {:restart_rate_limited, message}}
    else
      :ok
    end
  end

  defp normalize(id), do: id |> String.trim() |> String.downcase()
end
