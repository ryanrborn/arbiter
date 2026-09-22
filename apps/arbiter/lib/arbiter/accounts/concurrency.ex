defmodule Arbiter.Accounts.Concurrency do
  @moduledoc """
  P8 (`docs/provider-account-design.md` §4.2–§4.4). **The account owns the
  ceiling; the workspace owns a cap on its use of that ceiling.**

      effective_cap(graph) = min(
          workspace_max,
          system_max,
          account_headroom(account, workspace),
          quota_headroom(account)
      )

      account_headroom(a, ws) =
          max(0, min(a.max_concurrent, share(ws, a)) - live_count(a))

  ## Why this module exists at all

  Before P8 the account-facing ceiling was `graphs × workspaces ×
  max_concurrent` (§4.1). A `Arbiter.Workflows.Conductor` is per-*Graph*, so
  two running graphs in one workspace at `max_concurrent: 4` already permitted
  8 workers on one account, and `system_max` — the only thing above them —
  knows nothing about accounts. Any per-Conductor tally reproduces that bug,
  so `live_count/1` is derived from `Arbiter.Worker.Registry` and nothing
  else.

  ## `live_count/1` is registry-derived, and that is the design

  It counts *processes*, via `Arbiter.Worker.Registry.live_dispatches/0`:
  workers currently registered whose workspace points at account `a` for the
  provider they were dispatched with. There is no counter to increment, so
  there is nothing to decrement — a worker that crashes, is killed, or exits
  without running `terminate/2` releases its slot the moment it dies. That is
  the same crash-safety the Conductor's other state has (rebuilt from live
  processes, never remembered).

  Note that `live_count/1` is account-wide even in the `share` term — a
  sibling workspace's live workers do eat into this workspace's headroom.
  That is §4.2's formula as written, and it follows from §4.3: the share is a
  cap on a *shared* ceiling, first-come-first-served between Conductors, not a
  reservation of slots held open for a quiet workspace.

  ## Both terms are opt-in, and `nil` means "no constraint"

  `max_concurrent` migrates to `nil` (§4.4) and `share` has never been
  populated by anything but an explicit `arb account attach --share N`. With
  both `nil` the headroom is `:unlimited` and dispatch behaves exactly as it
  did before P8, bit-for-bit. When only one is set, that one bounds: `min/2`
  over an absent constraint is the present one.
  """

  require Ash.Query

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @type headroom :: non_neg_integer() | :unlimited

  @doc """
  How many workers are live on `account` right now — the one authoritative
  counter (§4.2). Derived from `Arbiter.Worker.Registry`, never stored.

  A worker that recorded no provider at dispatch counts against its
  workspace's default provider (`Arbiter.Quota.default_provider/1`), which is
  the same assumption the Conductor's quota clamp already makes for a
  workspace's dispatches.
  """
  @spec live_count(ProviderAccount.t() | String.t() | nil) :: non_neg_integer()
  def live_count(%ProviderAccount{id: id, provider: provider}) do
    case linked_workspace_ids(id) do
      workspace_ids when map_size(workspace_ids) == 0 ->
        0

      workspace_ids ->
        code = Atom.to_string(provider)

        WorkerRegistry.live_dispatches()
        |> Enum.filter(&Map.has_key?(workspace_ids, &1.workspace_id))
        |> count_matching(code)
    end
  rescue
    # A ceiling that cannot be read must not stop dispatch: an unreadable
    # count reads as "nothing is running", which leaves the headroom at its
    # maximum rather than holding the fleet.
    _ -> 0
  end

  def live_count(account_id) when is_binary(account_id),
    do: account_id |> Resolver.get() |> live_count()

  def live_count(_), do: 0

  @doc """
  `live_count/1` narrowed to one workspace: the live workers *this* workspace
  is contributing to its account's count, for `provider`.

  Not part of §4.2's formula — the ceiling is account-wide and deliberately
  blind to which workspace is using it. This is what a caller that subtracts
  its own in-flight work from an absolute cap needs to hand `clamp/3`.
  """
  @spec workspace_live_count(String.t() | nil, atom() | String.t() | nil) :: non_neg_integer()
  def workspace_live_count(workspace_id, provider) when is_binary(workspace_id) do
    case Arbiter.Quota.provider_code(provider) do
      nil ->
        0

      code ->
        WorkerRegistry.live_dispatches()
        |> Enum.filter(&(&1.workspace_id == workspace_id))
        |> count_matching(code)
    end
  rescue
    _ -> 0
  end

  def workspace_live_count(_workspace_id, _provider), do: 0

  @doc """
  `max(0, min(a.max_concurrent, share(ws, a)) - live_count(a))` — §4.2,
  verbatim — or `:unlimited` when neither term is set (§4.4's default) and
  when there is no account to bound at all.

  `workspace` may be a `Arbiter.Tasks.Workspace` or a workspace id.
  """
  @spec account_headroom(ProviderAccount.t() | nil, Workspace.t() | String.t() | nil) ::
          headroom()
  def account_headroom(nil, _workspace), do: :unlimited

  def account_headroom(%ProviderAccount{} = account, workspace) do
    share = Resolver.share(workspace_id(workspace), account.provider)

    case ceiling(account.max_concurrent, share) do
      nil -> :unlimited
      limit -> max(0, limit - live_count(account))
    end
  rescue
    _ -> :unlimited
  end

  @doc """
  `account_headroom/2` for the account `workspace_id` is metered under for
  `provider`. `:unlimited` when the workspace is linked to no account — a
  pure read, so an unlinked workspace is never provisioned one just to be
  told it has no ceiling.
  """
  @spec headroom(String.t() | nil, atom() | String.t() | nil) :: headroom()
  def headroom(workspace_id, provider) do
    workspace_id
    |> Resolver.account(provider)
    |> account_headroom(workspace_id)
  end

  @doc """
  Fold a headroom into a caller's own absolute cap.

  `account_headroom/2` answers "how many *more*"; `base` is an absolute
  ceiling that the caller will itself subtract its in-flight work from
  (`Conductor`: `cap - active_ids`; `Board.Snapshot`: `slots_total -
  running`). Adding those `already_counted` workers back converts the
  headroom into the caller's frame, so the account term bites exactly once.
  Folding a headroom straight into `min/2` instead would subtract the
  caller's own live workers twice and silently strangle a single graph to
  roughly half the ceiling the operator configured.
  """
  @spec clamp(non_neg_integer(), headroom(), non_neg_integer()) :: non_neg_integer()
  def clamp(base, :unlimited, _already_counted), do: base

  def clamp(base, headroom, already_counted)
      when is_integer(headroom) and is_integer(already_counted),
      do: min(base, already_counted + headroom)

  # ---- internals ----------------------------------------------------------

  # `min` over two optional constraints: an absent one imposes nothing.
  defp ceiling(nil, nil), do: nil
  defp ceiling(nil, share) when is_integer(share), do: share
  defp ceiling(max_concurrent, nil) when is_integer(max_concurrent), do: max_concurrent

  defp ceiling(max_concurrent, share) when is_integer(max_concurrent) and is_integer(share),
    do: min(max_concurrent, share)

  # One query: the workspaces metered under this account, as a set. Leaner
  # than `Resolver.workspaces/1`, which loads and sorts the workspace rows for
  # display.
  defp linked_workspace_ids(account_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.Query.select([:workspace_id])
    |> Ash.read()
    |> case do
      {:ok, links} -> Map.new(links, &{&1.workspace_id, true})
      _ -> %{}
    end
  end

  # `Arbiter.Quota.provider_code/1` resolves `"gemini"` by probing PATH, so
  # each distinct provider string (and each workspace whose dispatch named
  # none) is resolved once per call rather than once per worker.
  defp count_matching(dispatches, code) do
    {count, _cache} =
      Enum.reduce(dispatches, {0, %{}}, fn dispatch, {count, cache} ->
        {resolved, cache} = resolve_code(dispatch, cache)
        {if(resolved == code, do: count + 1, else: count), cache}
      end)

    count
  end

  defp resolve_code(%{provider: nil, workspace_id: ws_id}, cache) do
    cached(cache, {:default, ws_id}, fn ->
      ws_id |> Arbiter.Quota.default_provider() |> Arbiter.Quota.provider_code()
    end)
  end

  defp resolve_code(%{provider: provider}, cache) do
    cached(cache, {:provider, provider}, fn -> Arbiter.Quota.provider_code(provider) end)
  end

  defp cached(cache, key, fun) do
    case Map.fetch(cache, key) do
      {:ok, value} -> {value, cache}
      :error -> value_into(cache, key, fun.())
    end
  end

  defp value_into(cache, key, value), do: {value, Map.put(cache, key, value)}

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id) when is_binary(id), do: id
  defp workspace_id(_), do: nil
end
