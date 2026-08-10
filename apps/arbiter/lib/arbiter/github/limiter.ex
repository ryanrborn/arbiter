defmodule Arbiter.GitHub.Limiter do
  @moduledoc """
  A shared, priority-aware request budget for every GitHub-calling path in the
  fleet (bd-3p5vqc).

  ## Why

  GitHub accounts a single primary quota (~5,000 REST requests/hr, plus a
  GraphQL points budget) **per owning account** — every Personal Access Token
  belonging to the same account draws from *one* pool, and so does the
  operator's interactive `gh`. Left ungoverned, low-value background polling
  (patrols, speculative refreshes) can exhaust that pool and starve
  high-value foreground work: a `server deploy`, a dispatch, a PR
  open/merge/finalize, a tracker transition, or a human debugging by hand.

  This limiter puts a ceiling on background traffic and a floor under
  foreground traffic. It does **not** try to precisely account every request —
  it cannot, because the operator's interactive `gh` shares the pool and
  happens entirely outside arbiter (see "Headroom, not accounting" below).

  ## Priority classes

    * `:foreground` — deploys, dispatch, PR open/merge/finalize, tracker
      transitions: anything a human or a task is actively waiting on. **Never
      throttled.** `acquire/3` always returns `:ok` for foreground, even at
      zero headroom or during a secondary-limit backoff. We would rather let a
      foreground call 403 on its own than ever have the limiter be the reason a
      deploy failed.

    * `:background` — patrol polling and speculative refreshes. Yields first.
      Pauses entirely once remaining primary quota falls to/below a reserved
      headroom band, and pauses hard when a secondary limit is detected.

  The ambient class for a process is set with `with_priority/2` and read with
  `current_priority/0`; the default is `:foreground` (fail safe — an un-tagged
  caller is never starved). Patrols wrap their poll body in
  `with_priority(:background, fn -> ... end)`.

  **The class lives in the process dictionary and does not cross a process
  boundary.** Work handed to a spawned `Task` reverts to the `:foreground`
  default, so a background sweep that fans out over `Task.start/1` silently
  reclassifies itself as foreground (bd-8y1i58). Use `start_task/2` for that.

  ## The reserve — a floor under the whole account

  Foreground being un-throttleable protects arbiter's own work, but GitHub
  meters per *user* across every token: an arbiter that spends the pool to zero
  starves the operator's interactive `gh`, unrelated CI, and every other tool on
  the account. `:github_limiter_foreground_reserve` puts a hard floor under
  that — at or below `remaining`, **all** arbiter traffic stops, foreground
  included, so the reserved band survives for a human. It is **off by default**
  (`0`): below a nearly-exhausted pool a foreground call would very likely 403
  anyway, but the limiter should not be the thing that fails a deploy unless the
  operator has asked for that trade. Enable with, e.g.:

      config :arbiter, :github_limiter_foreground_reserve, 500

  ## Pool identity — key on the POOL, not the credential

  A separate token does **not** buy a separate pool. The budget is keyed on a
  **pool identity** — for a PAT, the owning GitHub account (resolved via
  `GET /user`, cached). Two different PATs owned by the same account MUST share
  one budget; issuing two budgets over one shared pool would let the limiter
  hand out 2x the real allowance and cause exactly the starvation it exists to
  prevent.

  When the owning account cannot be established (probing disabled, resolution
  in flight, or `GET /user` failed) the credential is mapped to the `:shared`
  pool. The failure modes are asymmetric: wrongly assuming *separate* pools
  over-issues and starves foreground work; wrongly assuming *shared* merely
  under-issues. We **fail safe toward shared**.

  The pool count is not hardcoded: if a GitHub App installation is ever adopted
  it resolves to its own `{:account, login}` (a genuinely separate,
  installation-scaled pool) with no redesign — but nothing here assumes that
  today.

  ## Headroom, not accounting

  The operator's interactive `gh` shares the pool and is invisible to this
  limiter — it runs outside arbiter entirely. Because that traffic cannot be
  accounted, **reserving headroom is the only workable strategy**: below a
  configured threshold of remaining quota, background traffic pauses rather
  than degrading gracefully, leaving the reserved band for foreground work
  (and for the human's `gh`).

  ## The real numbers, and secondary limits

  The limiter is driven by GitHub's actual counters, never by guessing:

    * Every real response carries `x-ratelimit-*` headers; `gate/3` feeds them
      back via `observe/3` for free on every call.
    * When probing is enabled, a periodic poll of the **exempt** `/rate_limit`
      endpoint refreshes the numbers even when the fleet is idle, at zero quota
      cost.

  GitHub's **secondary** (abuse) limit is separate and invisible: a 403 can
  occur while `/rate_limit` still reports thousands remaining, and it only
  clears with genuine quiet — retry traffic is what sustains it. So a "403 with
  headroom showing" is treated as *back off hard* (`note_secondary/2` arms a
  cooldown during which background is fully paused), never as *retry soon*.

  ## Observability

  `stats/1` returns per-pool counters (foreground / background / paused /
  secondary trips) and the last-seen numbers, and the limiter logs a summary
  periodically — so the next incident is diagnosable from the server rather
  than by sampling GitHub from a laptop.

  ## Availability

  The limiter fails **open**: if the server is unavailable, `gate/3` lets the
  request through untouched. It is a protection layer, not a correctness gate —
  a limiter outage must never wedge every GitHub operation.
  """

  use GenServer

  require Logger

  @default_background_headroom 1_000
  @default_foreground_reserve 0
  @default_secondary_cooldown_ms 120_000
  @default_report_interval_ms 300_000
  @default_poll_interval_ms 60_000

  @priority_key {__MODULE__, :priority}

  @type priority :: :foreground | :background
  @type pool_id :: :shared | {:account, String.t()}
  @type rate_info :: %{
          optional(:remaining) => non_neg_integer() | nil,
          optional(:limit) => non_neg_integer() | nil,
          optional(:reset_at) => DateTime.t() | nil
        }

  defmodule Paused do
    @moduledoc """
    Returned by `Arbiter.GitHub.Limiter.gate/3` when a background request is
    withheld to reserve headroom for foreground work. Each GitHub client maps
    this (via its `transport_error/1`) into its own error struct, so callers
    see an ordinary "try later" failure and issue **zero** real GitHub traffic.
    """
    defexception [:reason, :priority]

    @impl true
    def message(%__MODULE__{reason: reason}) do
      "arbiter GitHub limiter: background request paused (#{reason}) to reserve foreground headroom"
    end
  end

  # ---- Client: ambient priority -------------------------------------------

  @doc "Read the ambient priority for the current process (default `:foreground`)."
  @spec current_priority() :: priority()
  def current_priority, do: Process.get(@priority_key, :foreground)

  @doc """
  Run `fun` with the ambient priority set to `class` for the current process,
  restoring the previous value afterwards (even on raise). GitHub calls made
  synchronously within `fun` (same process) inherit `class`.
  """
  @spec with_priority(priority(), (-> result)) :: result when result: var
  def with_priority(class, fun)
      when class in [:foreground, :background] and is_function(fun, 0) do
    previous = Process.get(@priority_key, :foreground)
    Process.put(@priority_key, class)

    try do
      fun.()
    after
      Process.put(@priority_key, previous)
    end
  end

  @doc """
  Spawn an unlinked `Task` that runs `fun` with the ambient priority set to
  `class`.

  `with_priority/2` only tags the *calling* process, so a fire-and-forget
  `Task.start(fn -> github_call() end)` inside a background sweep issues
  **foreground** traffic (bd-8y1i58). Use this whenever GitHub work is handed
  to another process.
  """
  @spec start_task(priority(), (-> term())) :: {:ok, pid()} | {:error, term()}
  def start_task(class, fun) when class in [:foreground, :background] and is_function(fun, 0) do
    wrapped = fn -> with_priority(class, fun) end

    # Supervised, not a raw `Task.start/1`: callers of this (e.g. the
    # dashboard's PR-state resolver) can write to the DB, and a bare `Task`
    # has no name a test's `on_exit` can find and wait on. Under
    # `Arbiter.TaskSupervisor` it is swept by `Arbiter.DataCase` before the
    # sandbox connection tears down, same as every other detached write path
    # (bd-9j4znl) — an untracked one was exactly the residual "client exited"
    # connection churn that survived the first round of that fix.
    case Process.whereis(Arbiter.TaskSupervisor) do
      pid when is_pid(pid) -> Task.Supervisor.start_child(pid, wrapped)
      nil -> Task.start(wrapped)
    end
  end

  # ---- Client: the request seam -------------------------------------------

  @doc """
  Gate a single GitHub request. Reads the ambient priority, asks the limiter
  whether the call may proceed, and — when allowed — runs `fun` (which performs
  the actual HTTP and returns a `Req.request/1`-shaped result), feeding the
  response's rate-limit headers back to the limiter.

  A withheld background call returns `{:error, %Paused{}}` **without** running
  `fun`, so no GitHub traffic is issued. Fails open: if the limiter is not
  running, `fun` is run untouched.
  """
  @spec gate(String.t(), (-> term()), GenServer.server()) :: term()
  def gate(token, fun, server \\ default_server()) when is_function(fun, 0) do
    priority = current_priority()

    case safe_acquire(token, priority, server) do
      :ok ->
        result = fun.()
        observe_result(token, result, server)
        result

      {:paused, reason} ->
        {:error, %Paused{reason: reason, priority: priority}}

      :unavailable ->
        # Fail open — the limiter is not running; do not block GitHub traffic.
        fun.()
    end
  end

  # The limiter the request seam gates through. Normally the app-wide singleton;
  # a test can point every GitHub-client choke point at an isolated instance by
  # setting `:github_limiter_server` (mirrors the injectable-clock test seams
  # used elsewhere in the codebase).
  defp default_server, do: Application.get_env(:arbiter, :github_limiter_server, __MODULE__)

  defp safe_acquire(token, priority, server) do
    acquire(token, priority, server)
  catch
    :exit, _ -> :unavailable
  end

  defp observe_result(token, {:ok, %Req.Response{status: status, headers: headers}}, server) do
    info = parse_headers(headers)
    observe(token, info, server)

    # A 403/429 while the primary counter still shows headroom is the signature
    # of a *secondary* limit (bd-3p5vqc). Back off hard rather than retry.
    if status in [403, 429] and is_integer(info.remaining) and info.remaining > 0 do
      note_secondary(token, server)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp observe_result(_token, _other, _server), do: :ok

  # ---- Client: limiter API ------------------------------------------------

  @doc """
  Ask whether a request of `priority` may proceed against `token`'s pool.
  Returns `:ok`, or `{:paused, :low_headroom | :secondary_backoff}` for a
  withheld background call. Counts the decision for observability.
  """
  @spec acquire(String.t(), priority(), GenServer.server()) ::
          :ok | {:paused, :low_headroom | :secondary_backoff | :foreground_reserve}
  def acquire(token, priority, server \\ __MODULE__) do
    GenServer.call(server, {:acquire, token, priority})
  end

  @doc "Feed observed rate-limit numbers into `token`'s pool."
  @spec observe(String.t(), rate_info(), GenServer.server()) :: :ok
  def observe(token, info, server \\ __MODULE__) do
    GenServer.cast(server, {:observe, token, normalize_info(info)})
  end

  @doc "Record a secondary-limit hit for `token`'s pool, arming a hard background backoff."
  @spec note_secondary(String.t(), GenServer.server()) :: :ok
  def note_secondary(token, server \\ __MODULE__) do
    GenServer.cast(server, {:note_secondary, token})
  end

  @doc "Resolve the pool id `token` currently maps to (`:shared` until resolved)."
  @spec pool_for(String.t(), GenServer.server()) :: pool_id()
  def pool_for(token, server \\ __MODULE__) do
    GenServer.call(server, {:pool_for, token})
  end

  @doc """
  Per-pool snapshot for observability: counts by priority class plus the
  last-seen numbers. Keyed by `pool_id`.
  """
  @spec stats(GenServer.server()) :: %{pool_id() => map()}
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # ---- Server -------------------------------------------------------------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    probe? = Keyword.get(opts, :probe, Application.get_env(:arbiter, :github_limiter_probe, true))

    state = %{
      background_headroom:
        Keyword.get(
          opts,
          :background_headroom,
          Application.get_env(
            :arbiter,
            :github_limiter_background_headroom,
            @default_background_headroom
          )
        ),
      foreground_reserve:
        Keyword.get(
          opts,
          :foreground_reserve,
          Application.get_env(
            :arbiter,
            :github_limiter_foreground_reserve,
            @default_foreground_reserve
          )
        ),
      secondary_cooldown_ms:
        Keyword.get(
          opts,
          :secondary_cooldown_ms,
          Application.get_env(
            :arbiter,
            :github_limiter_secondary_cooldown_ms,
            @default_secondary_cooldown_ms
          )
        ),
      clock_fun: Keyword.get(opts, :clock_fun, &DateTime.utc_now/0),
      # Resolves a token to `{:ok, account_login} | :error`. Injectable so the
      # pool-sharing logic is testable without live `GET /user` traffic.
      resolver_fun: Keyword.get(opts, :resolver_fun, &get_user_login/1),
      probe?: probe?,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      report_interval_ms: Keyword.get(opts, :report_interval_ms, @default_report_interval_ms),
      pools: %{},
      token_pools: %{},
      resolving: MapSet.new()
    }

    if probe? do
      Process.send_after(self(), :poll, state.poll_interval_ms)
      Process.send_after(self(), :report, state.report_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, token, priority}, _from, state) do
    {pool_id, state} = resolve(token, state)
    now = state.clock_fun.()
    pool = get_pool(state, pool_id)

    decision = decide(priority, pool, state, now)
    pool = bump_count(pool, priority, decision)
    state = put_pool(state, pool_id, pool)

    {:reply, decision, state}
  end

  def handle_call({:pool_for, token}, _from, state) do
    {pool_id, state} = resolve(token, state)
    {:reply, pool_id, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.pools, state}
  end

  @impl true
  def handle_cast({:observe, token, info}, state) do
    {pool_id, state} = resolve(token, state)

    pool =
      state
      |> get_pool(pool_id)
      |> merge_info(info)
      |> remember_token(token)

    {:noreply, put_pool(state, pool_id, pool)}
  end

  def handle_cast({:note_secondary, token}, state) do
    {pool_id, state} = resolve(token, state)
    now = state.clock_fun.()
    until = DateTime.add(now, state.secondary_cooldown_ms, :millisecond)

    pool = get_pool(state, pool_id)
    counts = Map.update!(pool.counts, :secondary_trips, &(&1 + 1))
    pool = %{pool | secondary_until: until, counts: counts}

    Logger.warning(
      "GitHub limiter: secondary rate limit on pool #{inspect(pool_id)} — pausing background until #{DateTime.to_iso8601(until)}"
    )

    {:noreply, put_pool(state, pool_id, pool)}
  end

  def handle_cast({:resolved, key, pool_id, token}, state) do
    state =
      state
      |> Map.update!(:token_pools, &Map.put(&1, key, pool_id))
      |> Map.update!(:resolving, &MapSet.delete(&1, key))

    # Carry any numbers already observed under :shared into the resolved pool so
    # we don't lose the reading, and remember a token for polling.
    pool = state |> get_pool(pool_id) |> remember_token(token)
    {:noreply, put_pool(state, pool_id, pool)}
  end

  def handle_cast({:resolve_failed, key}, state) do
    # Do not cache the failure — leave it unresolved (mapped to :shared) so a
    # later poll can retry. Fail safe toward shared.
    {:noreply, Map.update!(state, :resolving, &MapSet.delete(&1, key))}
  end

  @impl true
  def handle_info(:poll, state) do
    for {_pool_id, pool} <- state.pools, is_binary(pool.token) do
      poll_rate_limit(pool.token, self())
    end

    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:report, state) do
    log_report(state.pools)
    Process.send_after(self(), :report, state.report_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- Decisions ----------------------------------------------------------

  # Foreground is never throttled — except by the account-wide reserve, which is
  # opt-in and exists to leave a band for the operator's own `gh` (bd-8y1i58).
  defp decide(:foreground, pool, state, _now) do
    if below_reserve?(pool, state.foreground_reserve) do
      {:paused, :foreground_reserve}
    else
      :ok
    end
  end

  defp decide(:background, pool, state, now) do
    cond do
      below_reserve?(pool, state.foreground_reserve) -> {:paused, :foreground_reserve}
      secondary_active?(pool, now) -> {:paused, :secondary_backoff}
      low_headroom?(pool, state.background_headroom) -> {:paused, :low_headroom}
      true -> :ok
    end
  end

  defp below_reserve?(%{remaining: remaining}, reserve)
       when is_integer(remaining) and is_integer(reserve) and reserve > 0,
       do: remaining <= reserve

  defp below_reserve?(_pool, _reserve), do: false

  defp secondary_active?(%{secondary_until: nil}, _now), do: false

  defp secondary_active?(%{secondary_until: until}, now),
    do: DateTime.compare(now, until) == :lt

  defp low_headroom?(%{remaining: remaining}, headroom)
       when is_integer(remaining) and is_integer(headroom),
       do: remaining <= headroom

  defp low_headroom?(_pool, _headroom), do: false

  defp bump_count(pool, :foreground, :ok),
    do: update_in(pool.counts.foreground, &(&1 + 1))

  defp bump_count(pool, :background, :ok),
    do: update_in(pool.counts.background, &(&1 + 1))

  defp bump_count(pool, :background, {:paused, _reason}),
    do: update_in(pool.counts.background_paused, &(&1 + 1))

  defp bump_count(pool, :foreground, {:paused, _reason}),
    do: update_in(pool.counts.foreground_paused, &(&1 + 1))

  defp bump_count(pool, _priority, _decision), do: pool

  # ---- Pool state ---------------------------------------------------------

  defp empty_pool do
    %{
      remaining: nil,
      limit: nil,
      reset_at: nil,
      secondary_until: nil,
      token: nil,
      counts: %{
        foreground: 0,
        foreground_paused: 0,
        background: 0,
        background_paused: 0,
        secondary_trips: 0
      }
    }
  end

  defp get_pool(state, pool_id), do: Map.get(state.pools, pool_id, empty_pool())

  defp put_pool(state, pool_id, pool),
    do: Map.update!(state, :pools, &Map.put(&1, pool_id, pool))

  defp merge_info(pool, info) do
    pool
    |> maybe_put(:remaining, info[:remaining])
    |> maybe_put(:limit, info[:limit])
    |> maybe_put(:reset_at, info[:reset_at])
  end

  defp maybe_put(pool, _key, nil), do: pool
  defp maybe_put(pool, key, value), do: Map.put(pool, key, value)

  defp remember_token(%{token: nil} = pool, token) when is_binary(token),
    do: %{pool | token: token}

  defp remember_token(pool, _token), do: pool

  # ---- Pool identity resolution -------------------------------------------

  # Returns {pool_id, state}. On a cache miss, maps to :shared (fail safe) and,
  # when probing is enabled, kicks off an async `GET /user` resolution.
  defp resolve(token, state) when is_binary(token) do
    key = :erlang.phash2(token)

    case Map.get(state.token_pools, key) do
      nil ->
        state = maybe_start_resolution(state, key, token)
        {:shared, state}

      pool_id ->
        {pool_id, state}
    end
  end

  defp resolve(_token, state), do: {:shared, state}

  defp maybe_start_resolution(%{probe?: false} = state, _key, _token), do: state

  defp maybe_start_resolution(state, key, token) do
    if MapSet.member?(state.resolving, key) do
      state
    else
      server = self()
      resolver = state.resolver_fun
      Task.start(fn -> resolve_owner(key, token, resolver, server) end)
      Map.update!(state, :resolving, &MapSet.put(&1, key))
    end
  end

  defp resolve_owner(key, token, resolver, server) do
    case resolver.(token) do
      {:ok, login} -> GenServer.cast(server, {:resolved, key, {:account, login}, token})
      _ -> GenServer.cast(server, {:resolve_failed, key})
    end
  end

  defp get_user_login(token) do
    base = Application.get_env(:arbiter, :github_base_url, "https://api.github.com")

    opts =
      [
        method: :get,
        url: base <> "/user",
        headers: auth_headers(token),
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(stub_opts())

    case Req.request(opts) do
      {:ok, %Req.Response{status: 200, body: %{"login" => login}}} when is_binary(login) ->
        {:ok, login}

      _ ->
        :error
    end
  catch
    _, _ -> :error
  end

  # ---- Exempt /rate_limit poll --------------------------------------------

  defp poll_rate_limit(token, server) do
    Task.start(fn ->
      base = Application.get_env(:arbiter, :github_base_url, "https://api.github.com")

      opts =
        [
          method: :get,
          url: base <> "/rate_limit",
          headers: auth_headers(token),
          receive_timeout: 15_000,
          retry: false
        ]
        |> Keyword.merge(stub_opts())

      case Req.request(opts) do
        {:ok, %Req.Response{status: 200, headers: headers}} ->
          observe(token, parse_headers(headers), server)

        _ ->
          :ok
      end
    end)
  end

  defp auth_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "arbiter"}
    ]
  end

  defp stub_opts do
    case Application.get_env(:arbiter, :github_limiter_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  # ---- Header parsing -----------------------------------------------------

  @doc false
  def parse_headers(headers) do
    %{
      remaining: to_int(header(headers, "x-ratelimit-remaining")),
      limit: to_int(header(headers, "x-ratelimit-limit")),
      reset_at: to_reset(header(headers, "x-ratelimit-reset"))
    }
  end

  defp normalize_info(info) do
    %{
      remaining: info[:remaining],
      limit: info[:limit],
      reset_at: info[:reset_at]
    }
  end

  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [val | _] -> val
      val when is_binary(val) -> val
      _ -> nil
    end
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == name, do: v
      _ -> nil
    end)
  end

  defp header(_headers, _name), do: nil

  defp to_int(nil), do: nil

  defp to_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp to_int(val) when is_integer(val), do: val
  defp to_int(_), do: nil

  defp to_reset(nil), do: nil

  defp to_reset(val) do
    case to_int(val) do
      nil -> nil
      epoch -> DateTime.from_unix!(epoch)
    end
  rescue
    _ -> nil
  end

  # ---- Reporting ----------------------------------------------------------

  defp log_report(pools) when map_size(pools) == 0, do: :ok

  defp log_report(pools) do
    summary =
      pools
      |> Enum.map(fn {pool_id, pool} ->
        c = pool.counts

        "#{inspect(pool_id)} remaining=#{inspect(pool.remaining)} " <>
          "fg=#{c.foreground} fg_paused=#{c.foreground_paused} " <>
          "bg=#{c.background} bg_paused=#{c.background_paused} " <>
          "secondary_trips=#{c.secondary_trips}"
      end)
      |> Enum.join(" | ")

    Logger.info("GitHub limiter: #{summary}")
  end
end
