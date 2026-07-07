defmodule ArbiterCli.ConfigSchema do
  @moduledoc """
  A comprehensive, human-readable reference for every key `workspace.config`
  accepts — printed by `arb config schema` and appended to `arb config --help`
  / `arb workspace --help`.

  `arbiter_cli` is a standalone escript with no runtime dependency on the
  `arbiter` core app (it talks to the server over HTTP), so the enum lists
  below are literal copies rather than live calls into
  `Arbiter.Tasks.Workspace.Changes.ValidateConfig` and its sibling modules.
  `ArbiterCli.ConfigSchemaTest` (a test-only `{:arbiter, in_umbrella: true,
  only: :test}` dependency) asserts every list here is byte-for-byte equal to
  the corresponding `valid_*/0` function on the server, so a change to the
  validator without a matching update here fails CI instead of silently
  drifting.
  """

  @tracker_types ~w(none jira shortcut linear github gitlab)
  @merger_strategies ~w(direct gitlab github)
  @agent_types ~w(claude gemini codex)
  @routing_policies ~w(static by_priority by_difficulty by_budget round_robin)
  @security_modes ~w(auto strict bypass)
  @sandbox_filesystems ~w(worktree none)
  @safe_default_categories ~w(no_destructive_fs no_force_push no_secret_reads no_outside_writes no_pr_create)
  @review_automation_modes ~w(auto report_only propose flag notify)
  @quota_modes ~w(throttle continue)

  @doc false
  def tracker_types, do: @tracker_types
  @doc false
  def merger_strategies, do: @merger_strategies
  @doc false
  def agent_types, do: @agent_types
  @doc false
  def routing_policies, do: @routing_policies
  @doc false
  def security_modes, do: @security_modes
  @doc false
  def sandbox_filesystems, do: @sandbox_filesystems
  @doc false
  def safe_default_categories, do: @safe_default_categories
  @doc false
  def review_automation_modes, do: @review_automation_modes
  @doc false
  def quota_modes, do: @quota_modes

  @doc "Renders the full workspace config reference as plain text."
  @spec render() :: String.t()
  def render do
    """
    WORKSPACE CONFIG REFERENCE

    Every top-level key of `workspace.config` (all optional; unknown keys are
    allowed for forward-compat). Enforced server-side by
    Arbiter.Tasks.Workspace.Changes.ValidateConfig — this reference is tested
    against that module so it can't silently drift.

    tracker  (map)
      type    one of: #{Enum.join(@tracker_types, ", ")}     (default: none)
      config  map, adapter-specific (host/project_key/owner/repo/…);
              credentials_ref: "env:VAR" | "secret:<key>" (see `arb workspace secret`)

    merge  (map)
      strategy             one of: #{Enum.join(@merger_strategies, ", ")}   (default: direct)
      config                map, adapter-specific (owner/repo/credentials_ref/…)
      auto_merge            bool — auto-merge an approved MR/PR         (default: false)
      pr_title_format       string, e.g. "conventional_commit"
      watchdog_max_polls    positive integer, or the string "infinity"
      watch_pipeline        bool — wait for CI before declaring merged  (default: false)

    agent / review_agent  (map — worker / reviewer respectively)
      type            one of: #{Enum.join(@agent_types, ", ")}, or a non-empty list of
                      those strings for a multi-provider pool           (default: claude)
      config          map, adapter-specific:
        model             concrete model name (overrides tier routing)
        credentials_ref   "env:VAR" | "secret:<key>"
        api_keys          list of credentials_refs, round-robin rotated
        tier_models       map, tier -> concrete model, e.g.
                          {"economy":"haiku","standard":"sonnet","premium":"opus"}
        thinking_argv     map, thinking level -> extra CLI argv, e.g.
                          {"high":["--effort","high"]}
      security        map — see "security" below; layered under agent.security
                      (workspace-level override of the install-wide default)

    security  (map, nested at agent.security)
      CANONICAL PATH: agent.security.permissions.mode

      permissions.mode          one of: #{Enum.join(@security_modes, ", ")}  (default: bypass)
        bypass  — headless-safe default; skips the interactive permission
                  classifier so a --print run can never freeze on a prompt.
                  Deny list is still enforced.
        auto    — classifier active (auto-accepts edits, can still pause to
                  ask); do NOT use for headless workers, only supervised runs.
        strict  — only explicitly allowed tools run; unlisted tools are denied.
      permissions.allow         list of operator-added allow rules (adapter-interpreted)
      permissions.deny          list of operator-added deny rules (adapter-interpreted)
      permissions.safe_defaults list of baseline destructive-op categories, each
                                one of: #{Enum.join(@safe_default_categories, ", ")}
                                (default: all five; set [] to opt a domain out)
      sandbox.enabled           bool                                     (default: true)
      sandbox.filesystem        one of: #{Enum.join(@sandbox_filesystems, ", ")}       (default: worktree)
      sandbox.network           bool — false cuts network-egress tools   (default: true)

      DEPRECATED (backward compat only, do not use in new configs):
        - top-level security.mode (use agent.security.permissions.mode instead)
        - agent.config.security_mode (use agent.security.permissions.mode instead)

    routing  (map)
      policy    one of: #{Enum.join(@routing_policies, ", ")}   (default: static)
      rules     map, policy-specific:
                  by_priority   — "P0".."P4" -> partial agent-config map
                  by_difficulty — "D0".."D4" -> partial agent-config map
                                  (default mapping: D0=economy/none .. D4=premium/high)
      base_policy         (by_budget only) "by_priority" | "by_difficulty" (default: by_priority)
      budget_usd_per_day  (by_budget only) number — degrades one model tier once
                          today's spend crosses this ceiling
      adapters            (round_robin only) list of partial agent-config maps,
                          cycled per dispatch

    review / review_gate  (map)
      required    bool — whether a review round gates completion
      max_rounds  positive integer — caps difficulty-derived round count (min wins)

    review_automation  (map)
      default          one of: #{Enum.join(@review_automation_modes, ", ")}
                       (report_only is an alias of propose; flag is an alias of notify)
      auto_authors     list of strings — PR authors that always get "auto"
      repo_overrides   map, repo name -> one of the modes above

    quota  (map — quota-aware dispatch throttle)
      on_exhaustion       one of: #{Enum.join(@quota_modes, ", ")}
      overage_alert_usd   positive number (or its JSON string form)
      throttle_threshold  number in (0, 1]

    conductor  (map)
      max_concurrent  positive integer — cap on concurrently-dispatched workers

    standing_orders  (list)
      list of short imperative strings (or {"title","detail"} objects), surfaced
      high in every worker's `arb prime` briefing. Manage with
      `arb workspace standing-order ls|add|rm`.

    repo_paths  (map, alias: rig_paths)
      repo name -> local worktree root path used to resolve a dispatch's working dir

    pr_patrol  (map)
      author_logins        list of forge logins — when non-empty, PRPatrol only
                           files follow-ups for PRs authored by one of these logins
      resolve_bot_threads  bool — resolve addressed bot/automated-reviewer review
                           threads (e.g. Copilot) after the follow-up worker
                           replies                                    (default: true)
      resolve_human_threads  bool — resolve addressed HUMAN-reviewer review
                           threads after the follow-up worker replies; left
                           false by default so a human confirms their own
                           threads                                    (default: false)

    review_patrol  (map)
      our_login  string — the fleet's own forge login, used to filter PR review
                threads down to the ones we participated in

    Secrets referenced by any `credentials_ref: "secret:<key>"` above are managed
    with `arb workspace secret set|rm|ls` — values are never echoed back.
    """
  end
end
