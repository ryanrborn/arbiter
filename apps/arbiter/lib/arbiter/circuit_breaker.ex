defmodule Arbiter.CircuitBreaker do
  @moduledoc """
  A single shared circuit breaker for every auto-filing / auto-escalating /
  auto-redispatching path in the fleet (bd-5jr49o, #1632).

  ## Why this exists

  One defect used to become N tickets, because every failure handler grew its
  own bound — or none at all. In one month, 33 duplicate filings were 10.3% of
  the backlog:

    * bd-7rxwzc — one unresolvable `repo` re-filed a PRPatrol follow-up per
      backoff window: 22 tickets.
    * bd-8lnnnt — 14 identical pre-flight auth escalations in 75 minutes.
    * bd-6bg54c — 303+ Watchdog retries, an escalation roughly every 30 minutes.
    * bd-brwx7w — two undeduplicated pollers escalating the same merge block
      about once a minute, indefinitely.

  Each was fixed case-specifically, and the next handler re-learned the lesson
  (PRPatrol's re-file loop recurred 27 days after its first fix). This module is
  the generic version: one primitive, adopted at every such path, so a new
  handler inherits the bound instead of re-deriving it.

  ## Semantics

  Keyed by **signature** = workspace + kind + normalised subject (see
  `Arbiter.CircuitBreaker.Signature`). For one signature:

    * the first `K` triggers inside the window are **allowed**;
    * the `K+1`-th trips the breaker: the action is **suppressed**, and exactly
      **one** coordinator escalation is emitted naming the signature, the count
      and the window;
    * while open, every further trigger is suppressed silently — no second
      escalation, no action;
    * the breaker closes when a full window passes with **no** trigger at all,
      or when the coordinator resets it (`breaker_reset` MCP tool /
      `arb breaker reset`). A sustained flood therefore keeps it open for as
      long as the flood lasts, which is exactly the bd-brwx7w shape; a
      condition that genuinely resolves and later recurs pages again.

  Note that suppressed triggers refresh the window. "Open until the window
  expires" means *quiet* for a window, not *K triggers ago*: a poller firing
  once a minute against a 1-hour window never re-opens the floodgates.

  ## Fail-open

  Every failure mode here — breaker process down, escalation write failing,
  normalisation raising — resolves to `:allow`. A broken breaker must never be
  the reason a genuine alert is swallowed; over-paging is recoverable, silence
  is not.

  ## State is in-memory

  Counters live in this GenServer, not the database. A restart closes every
  breaker, which is the right default: a restart is exactly the kind of
  intervention that may have fixed the underlying condition, and the flood
  re-establishes the breaker within K triggers. `call_sites/0` is static, so
  `arb breaker list` still enumerates every adopted path on a freshly-booted
  server, with live counters for whichever have fired since boot.

  ## What is deliberately NOT on this primitive

  `Arbiter.Workflows.ReviewPatrol` keeps its own breakers (#1548's per-engagement
  loop signature, #1572's per-finding refutation tracking). Those are not
  count-in-window suppressors at all: they trip on a *semantic* predicate about
  one engagement — a repeat verdict on an unchanged SHA, a re-request disputing
  a standing verdict, blocking findings already answered on lines the push did
  not touch. There is no K and no window to port, so moving them here would
  rewrite their behaviour rather than refactor it. They sit alongside this
  module, not on it.

  ## Usage

      case CircuitBreaker.check(:pr_patrol_follow_up, [repo, pr_number],
             workspace_id: ws_id, task_ref: task.id) do
        :allow -> file_the_ticket()
        {:suppress, _info} -> :suppressed
      end

  or, when the action is a plain function:

      CircuitBreaker.guard(:my_kind, subject, [workspace_id: ws], fn -> ... end)
  """

  use GenServer

  alias Arbiter.CircuitBreaker.Signature
  alias Arbiter.Messages.Message

  require Logger

  @hour 60 * 60_000

  # Every adopted call site, with its default bound. This list is the contract
  # `arb breaker list` prints and `test/arbiter/circuit_breaker_adoption_test.exs`
  # asserts against — adding a breaker to a new path means adding it here, so
  # the registry can never silently drift from the code.
  #
  # Bounds are deliberately per-kind rather than global. Filing a ticket is
  # expensive and near-irreversible (a human closes it), so PRPatrol gets a tight
  # bound over a long window. Posting a coordinator escalation is cheap and is
  # the last line of defence behind four other breakers, so it gets a loose one —
  # it must only catch a true runaway, never an ordinary busy hour.
  @call_sites [
    %{
      kind: :pr_patrol_follow_up,
      module: Arbiter.Workflows.PRPatrol,
      description:
        "Filing a PRPatrol follow-up task for one PR. Bounds the bd-7rxwzc shape: " <>
          "file → dispatch fails → auto-close → re-file, forever. The default sits one " <>
          "above PRPatrol's own @max_dispatch_attempts (5) so it backstops the re-file " <>
          "paths that counter does not count — a task closed out-of-band, a worker " <>
          "reaped as a zombie — without pre-empting the case-specific logic, which " <>
          "legitimately files one extra follow-up when its give-up escalation fails " <>
          "to persist.",
      limit: 6,
      window_ms: 6 * @hour
    },
    %{
      kind: :watchdog_merge_escalation,
      module: Arbiter.Worker.Watchdog,
      description:
        "Watchdog merge-failure / auto-merge-stalled escalation for one MR. " <>
          "Bounds the bd-6bg54c shape: an escalation every ~30 minutes, indefinitely.",
      limit: 3,
      window_ms: 6 * @hour
    },
    %{
      kind: :preflight_auth_failed,
      module: Arbiter.Worker.Dispatch,
      description:
        "Pre-flight auth-check escalation raised when Agents.Preflight refuses a dispatch. " <>
          "Bounds the bd-8lnnnt shape: 14 identical pages in 75 minutes for one " <>
          "exhausted usage window. The default sits well above the retry volume " <>
          "bd-8lnnnt's own uncleared-page dedupe already absorbs, so this only fires on a " <>
          "genuine runaway rather than adding a second page to a condition that is " <>
          "already paged exactly once.",
      limit: 10,
      window_ms: @hour
    },
    %{
      kind: :dispatch_queue_redispatch,
      module: Arbiter.Workflows.DispatchQueue,
      description:
        "Re-dispatching a held task out of the DispatchQueue drain after repeated " <>
          "identical failures. Stops an undispatchable task from re-draining forever.",
      limit: 5,
      window_ms: @hour
    },
    %{
      kind: :coordinator_escalation,
      module: Arbiter.Messages.CoordinatorNotifier,
      description:
        "Last line of defence: every escalation the coordinator notifier sends, keyed by " <>
          "task + normalised subject line. Catches any auto-escalating path that has " <>
          "no breaker of its own.",
      limit: 8,
      window_ms: @hour
    }
  ]

  @default_limit 5
  @default_window_ms @hour

  @typedoc "Why a trigger was suppressed, and the state of the breaker that suppressed it."
  @type info :: %{
          signature: String.t(),
          workspace_id: String.t() | nil,
          kind: atom(),
          subject: String.t(),
          count: non_neg_integer(),
          suppressed: non_neg_integer(),
          limit: pos_integer(),
          window_ms: pos_integer(),
          tripped_now?: boolean()
        }

  # ---- public API ---------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Every registered call site, with the bound currently in effect for it.

  Static: present on a freshly-restarted server before any breaker has fired,
  which is what makes "restart and observe the registered call sites" a
  meaningful check.
  """
  @spec call_sites() :: [map()]
  def call_sites do
    Enum.map(@call_sites, fn site ->
      %{site | limit: limit_for(site.kind), window_ms: window_for(site.kind)}
    end)
  end

  @doc """
  The trigger bound for `kind`.

  Defaults come from `call_sites/0` and may be overridden per kind in config:

      config :arbiter, :circuit_breaker,
        pr_patrol_follow_up: [limit: 2, window_ms: 3_600_000]
  """
  @spec limit_for(atom()) :: pos_integer()
  def limit_for(kind), do: configured(kind, :limit, @default_limit)

  @doc "The window (ms) for `kind`. See `limit_for/1` for the config shape."
  @spec window_for(atom()) :: pos_integer()
  def window_for(kind), do: configured(kind, :window_ms, @default_window_ms)

  @doc """
  Record a trigger for `kind` + `subject` and decide whether the action may
  proceed.

  Returns `:allow` (proceed) or `{:suppress, info}` (do NOT perform the action).
  `info.tripped_now?` is true on the single call that crossed the bound.

  Options:

    * `:workspace_id` — scopes the signature and addresses the trip escalation.
    * `:limit` / `:window_ms` — override the bound for `kind`.
    * `:task_ref` — task id recorded on the trip escalation.
    * `:detail` — extra line(s) for the trip escalation body.
    * `:escalate` — set `false` to suppress without paging (tests, and any
      caller that pages for itself).
    * `:now` — millisecond clock override; tests drive window expiry with it.
    * `:escalate_fun` — 1-arity override for the escalation write (tests).
  """
  @spec check(atom(), term(), keyword()) :: :allow | {:suppress, info()}
  def check(kind, subject, opts \\ []) when is_atom(kind) and is_list(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    request = %{
      signature: Signature.signature(workspace_id, kind, subject),
      subject: Signature.normalize_subject(subject),
      workspace_id: workspace_id,
      kind: kind,
      limit: Keyword.get(opts, :limit) || limit_for(kind),
      window_ms: Keyword.get(opts, :window_ms) || window_for(kind),
      now: Keyword.get(opts, :now) || System.system_time(:millisecond)
    }

    case safe_call({:check, request}) do
      :allow ->
        :allow

      {:suppress, info} ->
        maybe_escalate(info, opts)
        {:suppress, info}

      :unavailable ->
        :allow
    end
  rescue
    # Fail open: a normalisation bug must never swallow a real action.
    e ->
      Logger.warning("CircuitBreaker.check/3 failed open: #{Exception.message(e)}")
      :allow
  end

  @doc """
  Run `fun` unless the breaker for `kind` + `subject` is open.

  Returns `{:ok, fun.()}` or `{:suppressed, info}`. Options are `check/3`'s.
  """
  @spec guard(atom(), term(), keyword(), (-> result)) :: {:ok, result} | {:suppressed, info()}
        when result: term()
  def guard(kind, subject, opts \\ [], fun) when is_function(fun, 0) do
    case check(kind, subject, opts) do
      :allow -> {:ok, fun.()}
      {:suppress, info} -> {:suppressed, info}
    end
  end

  @doc """
  Live breaker state, newest trigger first.

  Options: `:workspace_id`, `:kind`, `:open_only` to filter.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    case safe_call({:list, Map.new(opts)}) do
      :unavailable -> []
      entries -> entries
    end
  end

  @doc "Close one breaker by signature. `{:error, :not_found}` when unknown."
  @spec reset(String.t()) :: :ok | {:error, :not_found}
  def reset(signature) when is_binary(signature) do
    case safe_call({:reset, signature}) do
      :unavailable -> {:error, :not_found}
      result -> result
    end
  end

  @doc """
  Close every breaker matching `opts` (`:workspace_id`, `:kind`); all of them
  when `opts` is empty. Returns `{:ok, count_closed}`.
  """
  @spec reset_all(keyword()) :: {:ok, non_neg_integer()}
  def reset_all(opts \\ []) do
    case safe_call({:reset_all, Map.new(opts)}) do
      :unavailable -> {:ok, 0}
      result -> result
    end
  end

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{entries: %{}}}

  @impl true
  def handle_call({:check, request}, _from, state) do
    {reply, entry} = evaluate(Map.get(state.entries, request.signature), request)
    {:reply, reply, put_in(state.entries[request.signature], entry)}
  end

  def handle_call({:list, filters}, _from, state) do
    entries =
      state.entries
      |> Map.values()
      |> Enum.filter(&matches?(&1, filters))
      |> Enum.filter(fn entry -> not Map.get(filters, :open_only, false) or open?(entry) end)
      |> Enum.sort_by(& &1.last_at, :desc)
      |> Enum.map(&render/1)

    {:reply, entries, state}
  end

  def handle_call({:reset, signature}, _from, state) do
    if Map.has_key?(state.entries, signature) do
      {:reply, :ok, update_in(state.entries, &Map.delete(&1, signature))}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:reset_all, filters}, _from, state) do
    doomed =
      state.entries
      |> Map.values()
      |> Enum.filter(&matches?(&1, filters))
      |> Enum.map(& &1.signature)

    {:reply, {:ok, length(doomed)}, update_in(state.entries, &Map.drop(&1, doomed))}
  end

  # ---- evaluation ---------------------------------------------------------

  # Bound the memory an endless flood can hold: the count past the limit is
  # only ever reported, never compared.
  @max_events 1_000

  # The whole decision, as a pure function of the prior entry and this trigger.
  # An entry that has been quiet for a full window is discarded first, so a
  # resolved-then-recurring condition gets a fresh budget (and a fresh
  # escalation) rather than inheriting a stale open breaker.
  defp evaluate(entry, request) do
    entry = if expired?(entry, request), do: nil, else: entry
    # Captured BEFORE the trigger is recorded: "was already open" must not
    # depend on clock resolution, or two triggers landing in the same
    # millisecond would each read as the trip and page twice.
    was_open? = entry != nil and entry.tripped_at != nil
    entry = record(entry, request)

    cond do
      was_open? ->
        entry = %{entry | suppressed: entry.suppressed + 1}
        {{:suppress, info(entry, false)}, entry}

      entry.count > entry.limit ->
        entry = %{entry | tripped_at: request.now, suppressed: entry.suppressed + 1}
        {{:suppress, info(entry, true)}, entry}

      true ->
        {:allow, entry}
    end
  end

  # Quiet for a full window — not "K triggers ago". A suppressed trigger counts
  # as noise, so a sustained flood holds the breaker open indefinitely
  # (bd-brwx7w); only genuine silence closes it.
  defp expired?(nil, _request), do: false

  defp expired?(%{last_at: last_at}, %{now: now, window_ms: window_ms}),
    do: now - last_at >= window_ms

  defp record(nil, request) do
    %{
      signature: request.signature,
      workspace_id: request.workspace_id,
      kind: request.kind,
      subject: request.subject,
      limit: request.limit,
      window_ms: request.window_ms,
      events: [request.now],
      count: 1,
      suppressed: 0,
      tripped_at: nil,
      first_at: request.now,
      last_at: request.now
    }
  end

  defp record(entry, request) do
    cutoff = request.now - request.window_ms

    events =
      [request.now | entry.events]
      |> Enum.take_while(&(&1 > cutoff))
      |> Enum.take(@max_events)

    %{
      entry
      | events: events,
        count: length(events),
        limit: request.limit,
        window_ms: request.window_ms,
        last_at: request.now
    }
  end

  # `tripped_at != request.now` in `evaluate/2` distinguishes "tripped on this
  # very call" from "was already open", so the suppressed counter is only
  # incremented once per trigger even at identical clock values.
  defp info(entry, tripped_now?) do
    entry
    |> Map.take([:signature, :workspace_id, :kind, :subject, :count, :suppressed, :limit])
    |> Map.merge(%{window_ms: entry.window_ms, tripped_now?: tripped_now?})
  end

  defp open?(entry), do: entry.tripped_at != nil

  defp render(entry) do
    entry
    |> Map.take([
      :signature,
      :workspace_id,
      :kind,
      :subject,
      :count,
      :suppressed,
      :limit,
      :window_ms,
      :first_at,
      :last_at,
      :tripped_at
    ])
    |> Map.put(:open?, open?(entry))
  end

  defp matches?(entry, filters) do
    Enum.all?(filters, fn
      {:workspace_id, ws} -> entry.workspace_id == ws
      {:kind, kind} -> entry.kind == kind
      _other -> true
    end)
  end

  # ---- escalation ---------------------------------------------------------

  # The one page a tripped breaker is allowed to send. Written directly through
  # `Message.send_mail/1` rather than `CoordinatorNotifier`, because the
  # notifier's own escalate path is itself behind a breaker — routing this
  # through it would make a tripped `:coordinator_escalation` breaker unable to
  # announce itself.
  defp maybe_escalate(%{tripped_now?: false}, _opts), do: :ok

  defp maybe_escalate(info, opts) do
    if Keyword.get(opts, :escalate, true) do
      send_fun = Keyword.get(opts, :escalate_fun) || (&Message.send_mail/1)
      do_escalate(info, opts, send_fun)
    end

    :ok
  end

  defp do_escalate(%{workspace_id: nil} = info, _opts, _send_fun) do
    Logger.warning(
      "CircuitBreaker tripped with no workspace to page: #{info.signature} " <>
        "(#{info.count} triggers / #{info.window_ms}ms)"
    )

    :ok
  end

  defp do_escalate(info, opts, send_fun) do
    task_ref = Keyword.get(opts, :task_ref)

    send_fun.(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: task_ref || "system",
      workspace_id: info.workspace_id,
      task_ref: task_ref,
      subject: "circuit breaker tripped — #{info.kind} (#{info.count} in #{minutes(info)}m)",
      body: escalation_body(info, opts)
    })

    Logger.warning(
      "CircuitBreaker tripped: #{info.signature} — #{info.count} triggers in " <>
        "#{info.window_ms}ms (limit #{info.limit}); suppressing further actions"
    )

    :ok
  rescue
    e ->
      # Fail open on the page too: a failed write must not crash the caller's
      # real work. The action stays suppressed either way — the log line above
      # is the durable trace.
      Logger.warning("CircuitBreaker escalation failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalation_body(info, opts) do
    [
      "A repeated automatic action hit its circuit breaker and has been stopped.",
      "",
      "  signature: #{info.signature}",
      "  kind:      #{info.kind}",
      "  triggers:  #{info.count} in the last #{minutes(info)} minute(s) (limit #{info.limit})",
      "",
      Keyword.get(opts, :detail),
      "",
      "No further #{info.kind} action will run for this signature until the breaker",
      "closes — a full window with no further triggers — or you reset it:",
      "",
      "    arb breaker reset #{info.signature}",
      "",
      "This is one escalation for the whole flood, not one per occurrence. If the",
      "underlying condition is real, fix it and reset; if the signature is too",
      "broad, narrow it at the call site."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp minutes(%{window_ms: ms}), do: div(ms, 60_000)

  # ---- plumbing -----------------------------------------------------------

  defp configured(kind, key, fallback) do
    declared =
      case Enum.find(@call_sites, &(&1.kind == kind)) do
        nil -> fallback
        site -> Map.fetch!(site, key)
      end

    :arbiter
    |> Application.get_env(:circuit_breaker, [])
    |> Keyword.get(kind, [])
    |> Keyword.get(key, declared)
  end

  # Fail open when the breaker process is not running (a test that boots a
  # partial tree, a supervisor restart mid-flight). `:unavailable` is mapped to
  # "allow" by every caller above.
  defp safe_call(message) do
    GenServer.call(__MODULE__, message, 5_000)
  catch
    :exit, _ -> :unavailable
  end
end
