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
    Arbiter.Tasks,
    Arbiter.Messages,
    Arbiter.Workers,
    Arbiter.Usage,
    Arbiter.Quota,
    Arbiter.Workflows,
    Arbiter.Reviews,
    Arbiter.Settings,
    Arbiter.Skills
  ]

# Local HTTP proxy that intercepts Claude CLI traffic to capture Anthropic's
# `anthropic-ratelimit-unified-*` quota headers (bd-5boun6). Worker spawns get
# `ANTHROPIC_BASE_URL` pointed at this proxy so every request is recorded.
config :arbiter, :anthropic_proxy,
  enabled: true,
  base_url: "http://127.0.0.1:4848/proxy/anthropic"

# Quota-aware dispatch throttle (bd-7cd38f). Governs what the fleet dispatcher
# does when the workspace nears / crosses the Anthropic 5h quota cap, consuming
# the quota snapshots captured by the proxy above (bd-5boun6):
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

# Direct Gemini CLI + Antigravity quota tracking (bd-57ukgb). Unlike the
# Anthropic snapshot (passively captured by the proxy), these fetch live from
# Google's Cloud Code Assist API when `GET /api/quota` / `arb quota` / the MCP
# `quota_get` tool is invoked. Enabled by default; `config/test.exs` turns it
# off so the quota surface stays a pure DB read under test.
config :arbiter, :cloud_code_quota, enabled: true

# Finch receive_timeout for the proxy's upstream requests to api.anthropic.com,
# in milliseconds. Because the proxy streams chunk-by-chunk, this is a
# per-chunk idle timeout — a generous value buys time-to-first-token headroom
# for large-context Opus calls without capping long healthy generations.
# Override at runtime with ANTHROPIC_PROXY_RECEIVE_TIMEOUT (ms).
config :arbiter_web, :anthropic_proxy, receive_timeout: 120_000

# Install-wide default acolyte security posture (the floor every spawn
# inherits before per-domain workspace overrides). The hardcoded safe baseline
# lives in `Arbiter.Agents.SecurityPolicy.base/0` — auto mode, a non-empty
# destructive-op deny list, worktree-scoped filesystem. Set this to override
# the install default without editing source or anyone's ~/.claude. Example:
#
#   config :arbiter, :acolyte_security_policy, %{
#     "permissions" => %{"mode" => "auto", "deny" => ["Bash(docker:*)"]},
#     "sandbox" => %{"network" => false}
#   }
#
# Per-domain overrides go in `workspace.config["agent"]["security"]`; see
# docs/worker-security.md.
config :arbiter, :acolyte_security_policy, %{}

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
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
