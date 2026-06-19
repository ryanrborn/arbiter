defmodule Arbiter.Agents.Agent do
  @moduledoc """
  Behaviour for the autonomous-agent harness that drives a polecat — the
  process that, given a prompt + worktree, writes the code, runs the tests,
  and signals completion with `arb done`.

  Mirrors `Arbiter.Trackers.Tracker` and `Arbiter.Mergers.Merger`: a thin
  behaviour, a dispatcher (`Arbiter.Agents`), one module per backend. Today
  the only adapter is `Arbiter.Agents.Claude`; Phase B of the harness
  design (`docs/agent-harness-design.md`) intentionally ships the seam
  before any second vendor.

  ## Division of responsibility

  The adapter is **stateless** w.r.t. the running OS process — port
  ownership, PubSub broadcast, line-cap buffering, and durable transcript
  capture all stay in the polecat / session module. The adapter only:

    * produces an argv (and optionally an env) for the spawn,
    * declares the regex that recognizes `arb done` in its stream,
    * parses each output line into display tuples + an updated session
      state,
    * surfaces the structured usage attrs the polecat persists into the
      `Arbiter.Usage.Event` ledger on session exit.

  This keeps adapters small (just the upstream-CLI shape) and the
  port-management code single-sourced.

  ## `opts` passed to `default_argv/2` and `init_session/1`

  A keyword list. Recognized keys (all optional):

    * `:model` — model name (`"haiku" | "sonnet" | "opus"` for Claude). When
      `nil` the adapter falls back to the CLI default — no behavioral change
      for existing workspaces.
    * `:api_key` — concrete credential to inject into the spawn env. The
      caller — `Arbiter.Agents.Claude.Config` for Claude — resolves which
      key (single-key today; round-robin from `api_keys` list in a follow-up).
    * `:config` — adapter-specific extra config (an opaque map).
    * `:security` — the resolved `Arbiter.Agents.SecurityPolicy` for this
      spawn (permission mode, allow/deny, sandbox). The caller (Dispatch /
      ReviewGate) resolves it from the workspace; the adapter maps it to its
      provider's mechanism. When absent the adapter MUST fall back to
      `SecurityPolicy.default/0` (the install-wide hardened floor) — a spawn is
      never un-permissioned.

  Adapters may read additional keys; unknown keys are ignored.

  ## Security-policy contract

  Every adapter maps the normalized `:security` policy to its provider and
  **MUST enforce a non-empty destructive-op deny baseline** (the policy's
  `permissions.safe_defaults`) in `:auto` and `:strict` modes — never an empty
  deny. Only `:bypass` (explicit opt-in) skips enforcement. The adapter must
  also **not** fall through to the host operator's personal agent config for
  permissions. The Claude adapter does this via
  `Arbiter.Agents.Claude.Security` + a generated `CLAUDE_CONFIG_DIR`
  `settings.json`; a second provider implements the same contract its own way.

  ## `init_session/1` shape

  Returns the per-session state map the polecat threads through
  `parse_line/2` and `usage_attrs/1`. Adapters own its shape — callers
  treat it as opaque.

  ## `parse_line/2`

  Given a complete output line and the prior session state, returns a list
  of `{text, arm_done?}` display tuples plus the updated session state.
  Tuples drive PubSub broadcasts and the durable transcript; `arm_done?`
  gates whether `done_sentinel/0` is matched against the tuple (so tool
  *results* that contain the substring "arb done" can't false-complete).

  Returning `[]` is fine: the line is absorbed into the state (e.g. a
  metadata-only stream event) without producing a display line.

  ## `usage_attrs/1`

  Returns the map persisted into `Arbiter.Usage.Event` on session exit.
  An empty map is fine (graceful degradation when the session never
  produced a usage-bearing event — test echo scripts, premature crashes).
  """

  @typedoc "Adapter-specific per-session state. Opaque to callers."
  @type session_state :: map()

  @typedoc "One display line plus whether `done_sentinel/0` should be matched against it."
  @type display_line :: {text :: String.t(), arm_done? :: boolean()}

  @typedoc "Structured attrs ready for `Arbiter.Usage.Event.create/1`."
  @type usage_attrs :: map()

  @doc """
  Argv to spawn for `prompt`. Adapters may bake in model / streaming flags
  and consult `opts` for per-dispatch overrides (e.g. `:model`).

  Returns `{:ok, argv}` where `argv` is `[exec, arg1, arg2, ...]` (the head
  is resolved by the session-spawn layer via `System.find_executable/1`),
  or `{:error, reason}` if the adapter cannot construct an argv (e.g. CLI
  not on `$PATH`).
  """
  @callback default_argv(prompt :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Environment variables to inject into the spawned subprocess, as a list of
  `{name, value}` tuples (`value = false` removes the env var from the
  inherited environment).

  This is the seam where credential / key rotation lives — adapters that
  rotate keys per-session decide here. Default implementation returns `[]`
  (inherit env unchanged); adapters opt in.
  """
  @callback spawn_env(opts :: keyword()) :: [{String.t(), String.t() | false}]

  @doc """
  Initial per-session state. Called once when the session is opened.
  """
  @callback init_session(opts :: keyword()) :: session_state

  @doc """
  Parse one complete output line into display tuples + an updated session
  state.
  """
  @callback parse_line(session_state, line :: String.t()) ::
              {[display_line], session_state}

  @doc """
  Regex matched against `arm_done?: true` display tuples to detect that
  the agent has signaled completion (`arb done`).
  """
  @callback done_sentinel() :: Regex.t()

  @doc """
  Structured usage attrs to persist into `Arbiter.Usage.Event` on session
  exit. Missing fields are fine (graceful degradation).
  """
  @callback usage_attrs(session_state) :: usage_attrs

  @doc """
  Provider key for ledger rows + dashboards (e.g. `"claude"`).
  """
  @callback provider() :: String.t()

  @doc """
  The concrete model id this adapter would dispatch with, given `opts` (the
  same keyword list passed to `default_argv/2`). Used to stamp the usage ledger
  and dashboards at spawn time — important for providers (e.g. Gemini) whose CLI
  emits no `init` event carrying the model, so the polecat can't learn it from
  the stream.

  Returns the resolved model string, or `nil` when the adapter lets the CLI pick
  its own default and can't name it. Optional — adapters whose model is always
  discoverable from the stream (e.g. Claude's `init` event) may omit it.
  """
  @callback resolved_model(opts :: keyword()) :: String.t() | nil

  @doc """
  Returns `true` when this adapter honors the normalized `SecurityPolicy`
  passed in `opts[:security]` — i.e., enforces a non-empty destructive-op deny
  baseline in `:auto`/`:strict` modes and does not fall through to the host
  operator's agent config.

  Defaults to `false` so that adapters added before implementing the security
  contract don't silently claim enforcement. The Claude adapter returns `true`.
  This value is surfaced in the `security_posture.policy_enforced` REST field so
  operators can see whether the declared posture is actually being enforced.
  """
  @callback security_enforced?() :: boolean()

  @doc """
  Argv for a cheap auth pre-flight probe — a single round-trip that verifies the
  CLI can authenticate (bd-awi4nw). Returns `{:ok, argv}`, or `{:error, reason}`
  when the CLI can't be resolved.

  `Arbiter.Agents.Preflight` runs this through a port (with the adapter's
  `spawn_env/1`) before a wave of workers is dispatched; a clean exit with no
  auth/credit signature means the credentials are valid. Optional — an adapter
  that omits it is treated as unprobeable (pre-flight is skipped, never blocks).
  """
  @callback auth_probe_argv(opts :: keyword()) :: {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks [spawn_env: 1, security_enforced?: 0, auth_probe_argv: 1, resolved_model: 1]
end
