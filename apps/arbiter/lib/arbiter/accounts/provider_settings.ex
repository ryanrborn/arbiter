defmodule Arbiter.Accounts.ProviderSettings do
  @moduledoc """
  A workspace's provider settings (bd-64apru): which provider accounts it may
  use **per role** — `:implementer` (the worker, its resumes and fix passes)
  and `:reviewer` (the ReviewGate reviewer) — in what preference order, and
  its concurrency share of each (`docs/provider-account-design.md` §4.3).

  This is the candidate set provider routing selects from (bd-40pzpj):
  `effective/2` is the one read, and it always answers, attached or not.

  ## Where it lives

  On the `workspace_provider_accounts` join row routing and the quota/credential
  surfaces already read, not in a second config tree:

    * `implementer_position` / `reviewer_position` — the account's place in
      that role's order; `nil` means "not allowed for this role". A link with
      neither set is what every link was before this: a metering/credential
      link only.
    * `share` — unchanged, the §4.3 cap `Arbiter.Accounts.Concurrency` reads.
      It is per account, not per role: both roles draw on the same slots.

  §3.4's cardinality still holds — one account per provider per workspace —
  so the implementer and the reviewer cannot sit on two *different* Claude
  accounts. `add/3` refuses that (`{:error, {:provider_taken, account}}`)
  rather than silently re-pointing a link the other role depends on.

  ## Resolution, and the fallback

  `effective/2` returns `%{role:, source:, candidates:}`:

    * `:attached` — accounts attached to the role, in preference order.
    * `:agent_type` (implementer) / `:review_agent_type` (reviewer) — nothing
      attached, so the hand-written `agent.type` / `review_agent.type` list is
      honoured, each type paired with the account its provider is metered
      under (or `nil`).
    * `:implementer` — a reviewer with nothing attached and no
      `review_agent.type` runs on the implementer's effective set, exactly as
      `Arbiter.Agents` falls back today.
    * `:default` — an implementer with neither: `claude`.

  ## Keeping `agent.type` honest

  Today's dispatch still reads `agent.type` / `review_agent.type` through
  `Arbiter.Agents.ProviderPool`. Every write here projects the role's attached
  accounts onto the matching key (deduplicated adapter types, in order; a
  single type as a scalar), so the attached set is what actually dispatches and
  nobody hand-edits those keys. Removing a role's last account leaves the key
  as last written — it becomes the fallback the page then shows — rather than
  resetting a workspace's providers behind the operator's back.
  """

  require Ash.Query

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace

  @type role :: :implementer | :reviewer
  @type source :: :attached | :agent_type | :review_agent_type | :implementer | :default

  @type candidate :: %{
          agent_type: String.t(),
          provider: atom() | nil,
          account: ProviderAccount.t() | nil,
          share: non_neg_integer() | nil,
          ceiling: non_neg_integer() | nil,
          cap: non_neg_integer() | nil
        }

  @type resolved :: %{role: role(), source: source(), candidates: [candidate()]}

  @roles [:implementer, :reviewer]
  @position_field %{implementer: :implementer_position, reviewer: :reviewer_position}
  @config_key %{implementer: "agent", reviewer: "review_agent"}

  # Account provider → the adapter (`Arbiter.Agents.valid_agent_types/0`) that
  # runs it. Both Google CLIs run under the `gemini` adapter, which picks agy
  # or gemini by what is installed.
  @agent_types %{
    claude: "claude",
    codex: "codex",
    gemini_cli: "gemini",
    antigravity: "gemini"
  }

  @doc "The roles a workspace configures accounts for."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "The adapter type (`agent.type` value) an account provider runs under."
  @spec agent_type(atom()) :: String.t() | nil
  def agent_type(provider), do: Map.get(@agent_types, provider)

  @doc """
  The effective provider setting for `role` — attached accounts, or the
  config fallback. See the module doc for each `source`.
  """
  @spec effective(Workspace.t(), role()) :: resolved()
  def effective(%Workspace{} = ws, role) when role in @roles do
    links = links(ws.id)

    case allowed(links, role) do
      [] -> fallback(ws, role, links)
      rows -> %{role: role, source: :attached, candidates: Enum.map(rows, &candidate/1)}
    end
  end

  @doc """
  Every account this workspace is linked to, with the account loaded, ordered
  by provider — the rows a share is set on.
  """
  @spec attachments(Workspace.t()) :: [WorkspaceProviderAccount.t()]
  def attachments(%Workspace{id: id}), do: id |> links() |> Enum.sort_by(&to_string(&1.provider))

  @doc """
  Allow `account_ref` (an id, `provider:slug` or bare slug) for `role`,
  appended at the end of the preference order. Reuses the workspace's link
  for that provider when it already points at this account, re-points a link
  no role uses, and refuses one another role depends on.

  Returns the workspace with `agent.type` / `review_agent.type` re-projected.
  """
  @spec add(Workspace.t(), role(), String.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def add(%Workspace{} = ws, role, account_ref) when role in @roles do
    with {:ok, account} <- Accounts.get_account(account_ref),
         :ok <- usable(account) do
      transact(ws, role, fn links -> attach(ws, role, account, links) end)
    end
  end

  @doc """
  Drop `account_id` from `role`. The link itself stays — it is still the
  account this workspace's provider is metered and credentialed under.
  """
  @spec remove(Workspace.t(), role(), String.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def remove(%Workspace{} = ws, role, account_id) when role in @roles do
    transact(ws, role, fn links ->
      links
      |> allowed(role)
      |> Enum.reject(&(&1.provider_account_id == account_id))
      |> write_order(role, links)
    end)
  end

  @doc "Swap `account_id` with its neighbour in `role`'s order (`:up` = preferred)."
  @spec move(Workspace.t(), role(), String.t(), :up | :down) ::
          {:ok, Workspace.t()} | {:error, term()}
  def move(%Workspace{} = ws, role, account_id, dir)
      when role in @roles and dir in [:up, :down] do
    transact(ws, role, fn links ->
      rows = allowed(links, role)

      case Enum.find_index(rows, &(&1.provider_account_id == account_id)) do
        nil ->
          {:ok, :unchanged}

        idx ->
          rows
          |> swap(idx, if(dir == :up, do: idx - 1, else: idx + 1))
          |> write_order(role, links)
      end
    end)
  end

  @doc """
  Attach, to `role`, every account the role's config fallback already
  resolves to — the one-click migration of a hand-written `agent.type` /
  `review_agent.type` onto accounts. Types with no linked account are skipped;
  `{:error, :nothing_to_adopt}` when none has one.
  """
  @spec adopt(Workspace.t(), role()) :: {:ok, Workspace.t()} | {:error, term()}
  def adopt(%Workspace{} = ws, role) when role in @roles do
    accounts =
      ws
      |> effective(role)
      |> Map.fetch!(:candidates)
      |> Enum.map(& &1.account)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    if accounts == [] do
      {:error, :nothing_to_adopt}
    else
      transact(ws, role, fn links ->
        ordered =
          Enum.map(accounts, fn a -> Enum.find(links, &(&1.provider_account_id == a.id)) end)

        write_order(ordered, role, links)
      end)
    end
  end

  @doc """
  Set (or clear, with `nil`) this workspace's §4.3 share of `account_id` — its
  cap on the account's concurrency ceiling. `{:error, :not_attached}` when the
  workspace has no link to that account.
  """
  @spec set_share(Workspace.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, WorkspaceProviderAccount.t()} | {:error, term()}
  def set_share(%Workspace{id: ws_id}, account_id, share)
      when is_nil(share) or is_integer(share) do
    case Enum.find(links(ws_id), &(&1.provider_account_id == account_id)) do
      nil -> {:error, :not_attached}
      link -> update(link, %{share: share})
    end
  end

  # ---- resolution ---------------------------------------------------------

  defp fallback(ws, :implementer, links) do
    case configured_types(ws, :implementer) do
      [] -> fallback_result(:implementer, :default, ["claude"], links)
      types -> fallback_result(:implementer, :agent_type, types, links)
    end
  end

  defp fallback(ws, :reviewer, links) do
    case configured_types(ws, :reviewer) do
      [] -> %{effective(ws, :implementer) | role: :reviewer, source: :implementer}
      types -> fallback_result(:reviewer, :review_agent_type, types, links)
    end
  end

  defp fallback_result(role, source, types, links) do
    candidates =
      Enum.map(types, fn type ->
        provider = Resolver.provider_atom(type)

        case Enum.find(links, &(&1.provider == provider)) do
          nil ->
            %{
              agent_type: type,
              provider: provider,
              account: nil,
              share: nil,
              ceiling: nil,
              cap: nil
            }

          link ->
            %{candidate(link) | agent_type: type}
        end
      end)

    %{role: role, source: source, candidates: candidates}
  end

  defp candidate(%WorkspaceProviderAccount{provider_account: %ProviderAccount{} = account} = link) do
    %{
      agent_type: agent_type(link.provider),
      provider: link.provider,
      account: account,
      share: link.share,
      ceiling: account.max_concurrent,
      cap: cap(account.max_concurrent, link.share)
    }
  end

  @doc """
  §4.2's `min(a.max_concurrent, share)` — the most workers this workspace may
  run on an account — with an absent term imposing nothing; `nil` = no cap.
  """
  @spec cap(non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer() | nil
  def cap(nil, share), do: share
  def cap(ceiling, nil), do: ceiling
  def cap(ceiling, share), do: min(ceiling, share)

  # The role's configured adapter types, registered ones only, in order.
  defp configured_types(ws, role) do
    valid = Arbiter.Agents.valid_agent_types()

    case get_in(ws.config || %{}, [@config_key[role], "type"]) do
      type when is_binary(type) -> [type]
      types when is_list(types) -> types
      _ -> []
    end
    |> Enum.filter(&(&1 in valid))
    |> Enum.uniq()
  end

  defp links(ws_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(workspace_id == ^ws_id)
    |> Ash.Query.load(:provider_account)
    |> Ash.read!()
  end

  defp allowed(links, role) do
    field = @position_field[role]

    links
    |> Enum.reject(&is_nil(Map.get(&1, field)))
    |> Enum.sort_by(&{Map.get(&1, field), to_string(&1.provider)})
  end

  # ---- writes -------------------------------------------------------------

  defp usable(%ProviderAccount{merged_into_id: survivor}) when not is_nil(survivor),
    do: {:error, {:merged_away, survivor}}

  defp usable(%ProviderAccount{enabled: false}), do: {:error, :disabled}
  defp usable(%ProviderAccount{}), do: :ok

  defp attach(ws, role, account, links) do
    rows = allowed(links, role)
    existing = Enum.find(links, &(&1.provider == account.provider))

    cond do
      Enum.any?(rows, &(&1.provider_account_id == account.id)) ->
        {:ok, :unchanged}

      is_nil(existing) ->
        with {:ok, link} <-
               Ash.create(WorkspaceProviderAccount, %{
                 workspace_id: ws.id,
                 provider: account.provider,
                 provider_account_id: account.id
               }) do
          write_order(rows ++ [link], role, links)
        end

      existing.provider_account_id == account.id ->
        write_order(rows ++ [existing], role, links)

      role_less?(existing) ->
        # The share was the previous account's cap; it does not carry over.
        with {:ok, link} <- update(existing, %{provider_account_id: account.id, share: nil}) do
          write_order(rows ++ [link], role, links)
        end

      true ->
        {:error, {:provider_taken, existing.provider_account}}
    end
  end

  defp role_less?(link), do: is_nil(link.implementer_position) and is_nil(link.reviewer_position)

  # Number `ordered` 0..n-1 for `role` and clear the role off every other link.
  defp write_order(ordered, role, links) do
    field = @position_field[role]
    ids = Enum.map(ordered, & &1.id)

    writes =
      Enum.with_index(ordered, fn link, idx -> {link, idx} end) ++
        for link <- links, link.id not in ids, not is_nil(Map.get(link, field)), do: {link, nil}

    Enum.reduce_while(writes, {:ok, :written}, fn {link, position}, acc ->
      if Map.get(link, field) == position do
        {:cont, acc}
      else
        case update(link, %{field => position}) do
          {:ok, _} -> {:cont, acc}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
  end

  defp swap(list, _i, j) when j < 0, do: list
  defp swap(list, _i, j) when j >= length(list), do: list

  defp swap(list, i, j) do
    list |> List.replace_at(i, Enum.at(list, j)) |> List.replace_at(j, Enum.at(list, i))
  end

  defp update(link, attrs) do
    link |> Ash.Changeset.for_update(:update, attrs) |> Ash.update()
  end

  # Run `fun` over the current links and project `role`'s config key, all or
  # nothing: a config the validator rejects must not leave the positions
  # half-written.
  defp transact(ws, role, fun) do
    Arbiter.Repo.transaction(fn ->
      with {:ok, _} <- fun.(links(ws.id)),
           {:ok, updated} <- project(ws, role) do
        updated
      else
        {:error, reason} -> Arbiter.Repo.rollback(reason)
      end
    end)
  end

  # Patches the freshly-read record, never the caller's copy: `patch_config`
  # merges into the record it is handed, and a stale one would write back
  # whatever another section changed since the page loaded.
  defp project(ws, role) do
    types = ws.id |> links() |> allowed(role) |> Enum.map(&agent_type(&1.provider)) |> Enum.uniq()

    with {:ok, fresh} <- Ash.get(Workspace, ws.id) do
      case types do
        [] ->
          {:ok, fresh}

        types ->
          value = if match?([_], types), do: hd(types), else: types
          patch = %{@config_key[role] => %{"type" => value}}
          Ash.update(fresh, %{patch: patch, unset_paths: []}, action: :patch_config)
      end
    end
  end
end
