# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :sqlite,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

# Configure Mix tasks and generators
config :arbiter,
  ecto_repos: [Arbiter.Repo],
  ash_domains: [
    Arbiter.Accounts,
    Arbiter.Tasks,
    Arbiter.Messages,
    Arbiter.Workers,
    Arbiter.Usage,
    Arbiter.Quota,
    Arbiter.Workflows,
    Arbiter.Reviews,
    Arbiter.ReviewGate,
    Arbiter.Settings,
    Arbiter.Skills,
    Arbiter.Loop,
    Arbiter.Events,
    Arbiter.Sessions
  ]

# Quota-aware dispatch throttle (bd-7cd38f). Governs what the fleet dispatcher
# does when the workspace nears / crosses the Anthropic 5h quota cap, consuming
# the quota snapshots `Arbiter.Quota.CloudProbe` polls off `/api/oauth/usage`
# (bd-b0zody; the pass-through proxy that used to capture the same figures off
# response headers was removed in bd-7cvh8z):
#
#   * on_exhaustion: :throttle (default) — near the cap, HOLD new dispatches in a
#     per-workspace draining queue and drain them in priority order as headroom
#     frees / the 5h window resets. Work is delayed, never dropped.
#   * on_exhaustion: :continue — dispatch proceeds past the cap (paid API
#     overage); overage spend is recorded and an alert fires once per
#     `overage_alert_usd` crossing, but dispatch never auto-stops.
#
# `throttle_threshold` is the `utilization_5h` at/above which :throttle holds
# (0.85 = Ryan's hand-enforced ceiling, between the dashboard's 0.7/0.9 bands).
# `overage_alert_usd` is the global default alert threshold for :continue, below
# a per-workspace `quota.overage_alert_usd` override.
#
# Per-workspace overrides live in `workspace.config["quota"]`; precedence is
# per-workspace > this global default > the hardcoded `:throttle`. Set
# `:gate` to a module to hard-override the gate (kill switch / tests).
config :arbiter, :quota,
  on_exhaustion: :throttle,
  throttle_threshold: 0.85,
  overage_alert_usd: 50.0

# Quota-bar color thresholds (bd-l4epbc). The topbar/usage-page bars color on
# projected *deficit minutes* — how long the window would run dry before
# reset at the current burn rate — not on absolute utilization (a raw
# used/elapsed ratio is alarming early in the window and meaningless late in
# it). See `ArbiterWeb.QuotaHelpers`.
#
#   * deficit_red_minutes / deficit_amber_minutes: the two color boundaries.
#   * sampling_floor_elapsed_minutes / sampling_floor_used: below these, a
#     single burst implies a nonsense burn rate, so the bar renders neutral
#     grey ("sampling") instead of guessing.
#   * wall_guard_used: utilization at/above which the bar is never better
#     than amber, regardless of pace — being on-pace and being out of quota
#     are independent facts.
config :arbiter_web, :quota_bar_colors,
  deficit_red_minutes: 60,
  deficit_amber_minutes: 20,
  sampling_floor_elapsed_minutes: 15,
  sampling_floor_used: 0.05,
  wall_guard_used: 0.95

# Direct Gemini CLI + Antigravity quota tracking (bd-57ukgb). Unlike the
# Anthropic snapshot (passively captured by the proxy), these fetch live from
# Google's Cloud Code Assist API when `GET /api/quota` / `arb quota` / the MCP
# `quota_get` tool is invoked. Enabled by default; `config/test.exs` turns it
# off so the quota surface stays a pure DB read under test.
config :arbiter, :cloud_code_quota, enabled: true

# Periodic refresh of the non-Anthropic quota providers (Codex, Gemini CLI,
# Antigravity) — `Arbiter.Quota.CloudProbe` (bd-ajh7bd). These have no passive
# proxy signal, so the prober fetches them on a timer, persists a snapshot, and
# broadcasts a quota_updated event; `GET /api/quota` then reads the persisted
# rows rather than fetching live. `config/test.exs` turns it off.
config :arbiter, :cloud_quota_probe, enabled: true, interval_ms: 300_000

# Install-wide default worker security posture (the floor every spawn
# inherits before per-domain workspace overrides). The hardcoded safe baseline
# lives in `Arbiter.Agents.SecurityPolicy.base/0` — auto mode, a non-empty
# destructive-op deny list, worktree-scoped filesystem. Set this to override
# the install default without editing source or anyone's ~/.claude. Example:
#
#   config :arbiter, :worker_security_policy, %{
#     "permissions" => %{"mode" => "auto", "deny" => ["Bash(docker:*)"]},
#     "sandbox" => %{"network" => false}
#   }
#
# Per-domain overrides go in `workspace.config["agent"]["security"]`; see
# docs/worker-security.md.
config :arbiter, :worker_security_policy, %{}

config :arbiter_web,
  ecto_repos: [Arbiter.Repo],
  generators: [context_app: :arbiter]

# Configures the endpoint
config :arbiter_web, ArbiterWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ArbiterWeb.ErrorHTML, json: ArbiterWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Arbiter.PubSub,
  live_view: [signing_salt: "0ekr3cZr"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  arbiter_web: [
    args:
      ~w(js/app.js js/theme.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/arbiter_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  arbiter_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/arbiter_web", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Force exqlite to compile from source on RHEL8/glibc<2.33 systems; the
# precompiled NIF requires glibc 2.33 which is not available on Amazon Linux 2
# or RHEL 8. This has no cost on systems that already have a compatible binary.
config :exqlite, force_build: true

# Terminal transport for browser-hosted coordinator sessions (bd-3ymdvi,
# RFC §5.3). Spelled out here rather than left to the module's defaults
# because §12 item 7 asks for exactly these numbers to be measured against a
# real session and then adjusted — they are guesses until then.
#
#   ring_bytes        replay ring the reader keeps per session; a reconnect
#                     inside it replays frames, outside it repaints
#   max_replay_bytes  largest gap still served from the pipe file rather than
#                     repainted — this is what makes a reconnect after an
#                     `arbiter` restart gapless
#   high_water_bytes  unacknowledged bytes at which a client is cut off and
#                     dropped to snapshot mode
#   read_chunk_bytes  ceiling on one frame's payload, i.e. how much a burst
#                     coalesces into before it is shipped
#   linger_ms         how long a reader outlives its last client, so a browser
#                     reload resumes instead of repainting
config :arbiter, Arbiter.Sessions.Stream,
  ring_bytes: 2_097_152,
  max_replay_bytes: 2_097_152,
  high_water_bytes: 262_144,
  low_water_bytes: 65_536,
  read_chunk_bytes: 65_536,
  poll_interval_ms: 25,
  alive_interval_ms: 1_000,
  linger_ms: 5_000

# Scrollback lines a `snapshot` reaches back for. tmux's pane history is
# 30,000 lines (§12 item 2); shipping all of it on every attach is a lot of
# bytes for a repaint, so the snapshot is a window onto it.
config :arbiter, :sessions_snapshot_lines, 2_000

# Persisted raw PTY transcript (§11, phase 9). `max_bytes` is a per-session
# safety ceiling — measured sessions land well under it (§11: 25 MB for a
# long JSONL, and the raw stream is smaller still). `retention_days` outlives
# Claude Code's own ~21-day session-store prune (§11's whole reason to exist)
# with margin for an operator's own investigation window.
config :arbiter, :sessions_transcript,
  max_bytes: 100 * 1024 * 1024,
  retention_days: 30

# See `Arbiter.Sessions.TranscriptRetention` moduledoc for the sweep cadence.
config :arbiter, :sessions_transcript_retention, interval_ms: 6 * 60 * 60_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
