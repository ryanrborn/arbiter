defmodule Arbiter.Sessions.Session do
  @moduledoc """
  One browser-hosted coordinator session — RFC §7.4 item 4
  (`docs/browser-hosted-coordinator-sessions.md`, bd-bpt0ag / phase 1).

  A row is the **durable identity** of a session whose actual process lives
  outside the BEAM entirely: a `systemd-run --user --scope` transient unit
  holding a tmux server holding the agent's PTY (§4.3). Arbiter keeps no port,
  pid or fd — see `Arbiter.Sessions` — so this table plus the two derived
  names in `Arbiter.Sessions.Naming` are the *whole* of what survives a
  `systemctl --user restart arbiter`, and the boot-time adoption sweep
  (`Arbiter.Sessions.Adoption`) reconciles them against what systemd and tmux
  still have running.

  ## Fields

    * `provider` — which agent CLI runs in the pane. `:claude_code` is the
      first (and currently only) implementation; the launch command itself is
      behind `Arbiter.Sessions.Provider` so a second provider is an adapter,
      not a schema change.
    * `workspace_id` — **nullable on purpose**. `nil` means a cross-workspace
      session, which is the coordinator's normal shape (decision 6: a
      workspace-agnostic coordinator token). A bound session is one deliberately
      scoped to one workspace.
    * `scope_unit` / `tmux_socket` — the OS handles, derived from `id` at create
      time and never accepted from a caller. Stored rather than only computed so
      a row remains self-describing if the naming scheme ever changes under it.
    * `config_dir` — the session's `CLAUDE_CONFIG_DIR` (§9.1). Nullable: phase 1
      launches with no provisioning, phase 3 fills it in.
    * `cwd` — the agent's working directory.
    * `provider_session_id` — the **current** provider-side session id, i.e. the
      basename of the JSONL the CLI is appending to. Nullable at launch (the CLI
      picks it), and **updated on rollover**: a long session that hits
      `--resume`/compaction rolls onto a new id, and §7.5 is explicit that the
      row must track the current one, not the launch one. This is the string
      `Arbiter.Usage.Event.session_id` carries, which is how ledger rows join
      back to a session (`Arbiter.Sessions.usage_events/1`).
    * `auth_mode` — `:seeded_credentials` (mode B, the default per Amendment 2 —
      the operator's own grant copied into the session config dir, and the only
      mode Remote Control works under) or `:oauth_token` (mode A, a revocable
      per-workspace token, no Remote Control). See §8.1.
    * `remote_control` — whether the session was launched with
      `--remote-control` (§8). Phase 8 sets it; phase 1 only records it.
    * `started_at` / `ended_at` / `last_client_at` — lifecycle. `last_client_at`
      is the idle-deadline input for phase 10's reaper (§4.6 item 2).
    * `status` — `:starting` (row written, scope not yet confirmed), `:running`
      (scope live), `:ended` (gone, for any reason).
    * `end_reason` — free text saying *why* it ended: an operator kill, a failed
      launch, or the adoption sweep finding the scope vanished. §4.6 requires the
      sweep to record a reason rather than silently flipping rows.

  ## No FK to the ledger

  `Usage.Event.session_id` references a session **by string**, deliberately
  (§7.4 item 4: "no FK churn"). It holds the *provider* session id for rows the
  existing ingest writes, and a session can roll through several of those, so a
  foreign key would be wrong as well as expensive.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Sessions,
    data_layer: AshSqlite.DataLayer

  alias Arbiter.Sessions.Naming

  @providers ~w(claude_code)a
  @auth_modes ~w(seeded_credentials oauth_token)a
  @statuses ~w(starting running ended)a

  @doc "Providers a session may run."
  @spec providers() :: [atom()]
  def providers, do: @providers

  @doc "Auth modes a session may launch under (§8.1)."
  @spec auth_modes() :: [atom()]
  def auth_modes, do: @auth_modes

  @doc "Lifecycle statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  sqlite do
    table "sessions"
    repo Arbiter.Repo

    custom_indexes do
      # One row per scope — enforced, not merely implied by `id`.
      index [:scope_unit], unique: true
      # The adoption sweep's read ("every row that isn't ended") and the
      # dashboard's list.
      index [:status]
      # The ledger join (`usage_events/1`) and the rollover lookup.
      index [:provider_session_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :provider,
        :workspace_id,
        :config_dir,
        :cwd,
        :provider_session_id,
        :auth_mode,
        :remote_control
      ]

      # The OS handles are a function of the id, so they are computed here
      # rather than accepted — a caller cannot point a row at somebody else's
      # scope or socket.
      change fn changeset, _context ->
        id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()

        case Naming.socket_path(id) do
          {:ok, socket} ->
            changeset
            |> Ash.Changeset.force_change_attribute(:id, id)
            |> Ash.Changeset.force_change_attribute(:scope_unit, Naming.scope_unit(id))
            |> Ash.Changeset.force_change_attribute(:tmux_socket, socket)

          {:error, :no_runtime_dir} ->
            Ash.Changeset.add_error(changeset,
              field: :tmux_socket,
              message:
                "cannot place the tmux socket: XDG_RUNTIME_DIR is unset, so this process " <>
                  "is not inside a systemd user session and cannot host a session scope"
            )
        end
      end
    end

    update :mark_running do
      description "The scope was confirmed live — at launch, or by the adoption sweep."
      accept []
      require_atomic? false
      change set_attribute(:status, :running)
      change set_attribute(:end_reason, nil)
    end

    update :mark_ended do
      description "The session is gone. `end_reason` says why; the sweep depends on it (§4.6)."
      accept [:end_reason]
      require_atomic? false
      change set_attribute(:status, :ended)

      change fn changeset, _context ->
        # Idempotent: re-ending an already-ended row keeps the first timestamp,
        # so a sweep that runs twice does not rewrite history.
        case Ash.Changeset.get_data(changeset, :ended_at) do
          nil -> Ash.Changeset.force_change_attribute(changeset, :ended_at, DateTime.utc_now())
          _ -> changeset
        end
      end
    end

    update :record_provider_session do
      description "Rollover: the CLI moved onto a new session id (§7.5)."
      accept [:provider_session_id]
      require_atomic? false
    end

    update :touch_client do
      description "A client attached or is still attached — the idle-deadline input (§4.6)."
      accept []
      require_atomic? false
      change set_attribute(:last_client_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      default :claude_code
      constraints one_of: @providers
    end

    attribute :workspace_id, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "nil = cross-workspace (the coordinator's normal shape)."
    end

    attribute :scope_unit, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "systemd transient unit name, e.g. arb-session-<id>.scope."
    end

    attribute :tmux_socket, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
      description "$XDG_RUNTIME_DIR/arbiter/session-<id>.sock."
    end

    attribute :config_dir, :string do
      public? true
      constraints max_length: 512, trim?: true
      description "CLAUDE_CONFIG_DIR for the session (§9.1); nil until phase 3."
    end

    attribute :cwd, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: true
    end

    attribute :provider_session_id, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Current provider-side session id; joins usage_events.session_id."
    end

    attribute :auth_mode, :atom do
      allow_nil? false
      public? true
      default :seeded_credentials
      constraints one_of: @auth_modes
    end

    attribute :remote_control, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :ended_at, :utc_datetime_usec, public?: true

    attribute :last_client_at, :utc_datetime_usec, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :starting
      constraints one_of: @statuses
    end

    attribute :end_reason, :string do
      public? true
      constraints max_length: 512, trim?: true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
