defmodule Arbiter.MCP.AgentConfig.Gemini do
  @moduledoc """
  The `Arbiter.MCP.AgentConfig` adapter for the Gemini *provider* — which is two
  different CLIs with two different, mutually-unreadable config formats:

  | CLI                     | reads                                          | per-spawn config? |
  | ----------------------- | ---------------------------------------------- | ----------------- |
  | upstream `gemini`       | `<worktree>/.gemini/settings.json`             | yes               |
  | `agy` (Antigravity)     | `$HOME/.gemini/config/mcp_config.json` (global) | **no**           |

  `Arbiter.Agents.Gemini.resolve_executable/0` prefers `agy` over `gemini` when
  both are on `PATH`, so on an Antigravity host the provider is *agy*, and
  writing `.gemini/settings.json` is writing a file nothing will ever read. This
  module therefore routes on the CLI flavour (`cli_flavour/1`) and returns an
  explicit `{:error, :unsupported}` for `agy` rather than silently emitting a
  dead file (bd-m8geh4).

  ## What agy actually reads (verified live, agy v1.2.5, 2026-09-17)

  agy's own embedded docs (`# MCP Servers (mcp_config.json)`, extractable with
  `strings -n 6 $(which agy) | grep -n 'Configuration File'`) enumerate exactly
  two locations:

    * **Global**: `~/.gemini/config/mcp_config.json`
    * **Plugin**: `plugins/<plugin_name>/mcp_config.json`, inside a
      *customization root*

  and its plugin docs name `.agents/plugins/` as an example customization root.
  That reads like a worktree-local hook, so it was probed end-to-end rather than
  assumed. It is not one — in `--print` (headless) mode, which is the only mode
  Arbiter ever runs, agy performs **no workspace customization discovery at
  all**.

  ### Probe (reproducible; ~4 agy turns)

      # 1. a local MCP endpoint that logs every request it receives
      PROBE=$(mktemp -d); cd "$PROBE"; git init -q .
      python3 -m http.server --bind 127.0.0.1 47821 &   # or any request logger

      # 2. the candidate worktree-local path, with the manifest agy documents
      mkdir -p .agents/plugins/arbiter
      echo '{"name":"arbiter"}' > .agents/plugins/arbiter/plugin.json
      cat > .agents/plugins/arbiter/mcp_config.json <<'JSON'
      {"mcpServers":{"arbiter":{"serverUrl":"http://127.0.0.1:47821/mcp",
        "headers":{"Authorization":"Bearer probe"},"enabledTools":["probe_ping"]}}}
      JSON

      # 3. run agy from that cwd and watch the endpoint
      agy -p "Call the probe_ping tool if you have it." --output-format text

  Results:

    * `.agents/plugins/arbiter/mcp_config.json` (+ `plugin.json`) — **zero**
      requests reached the endpoint; agy reported no such tool.
    * adding an `.agents/plugins.json` manifest (`{"entries":[{"path":
      ".agents/plugins"}]}`), the documented explicit-registration escape
      hatch — still **zero** requests.
    * control: the *same* plugin directory placed at
      `~/.gemini/config/plugins/<name>/` — full handshake
      (`server/discover` → `initialize` → `notifications/initialized` →
      `tools/list`) with `Authorization: Bearer <token>` on every request.
    * a second control ruled out folder trust and workspace discovery
      generally: a worktree-local `.agents/skills/<name>/SKILL.md` was likewise
      invisible to `agy -p`, with the worktree marked `TRUST_FOLDER` in
      `~/.gemini/trustedFolders.json`.

  `agy mcp list` / `agy plugin list` are **not** valid probes: they only report
  the user-level `mcp_config.json` and explicitly imported plugins, so both
  print "none" even while a global plugin server is connecting fine.

  There is also no config-dir environment variable to relocate per spawn — agy
  derives `~/.gemini` from `HOME` and exposes no `AGY_*`/`GEMINI_*` override
  (`strings $(which agy) | grep -oE '(AGY|GEMINI)_[A-Z0-9_]+'`). Per-spawn
  isolation therefore needs a per-worker `HOME`, which is the T6a spike — not
  this module's business.

  ## Consequence

  `write_mcp_config/2` refuses for agy with `{:error, :unsupported}`, and
  `Arbiter.Worker.Dispatch` logs that refusal at `:error` at dispatch time. An
  agy worker keeps working — it falls back to the `arb` CLI for task reads and
  progress notes — but the operator is told, loudly, that it has no typed
  Arbiter MCP tools, instead of a `.gemini/settings.json` sitting in the
  worktree implying otherwise.

  `agy_config_map/1` is kept and tested because agy's *schema* is confirmed
  correct (see below); only its **location** is unavailable. Whatever ships the
  per-worker `HOME` can write `agy_config_map/1`'s output straight to
  `<home>/.gemini/config/mcp_config.json`.

  ## The two schemas

  Upstream `gemini` (`<worktree>/.gemini/settings.json`) — `httpUrl`,
  `includeTools`:

      {"mcpServers": {"arbiter": {
        "httpUrl": "http://127.0.0.1:4848/mcp",
        "headers": {"Authorization": "Bearer <scope-token>"},
        "includeTools": ["task_show", ...]}}}

  `agy` (`mcp_config.json`) — `serverUrl`, `enabledTools`:

      {"mcpServers": {"arbiter": {
        "serverUrl": "http://127.0.0.1:4848/mcp",
        "headers": {"Authorization": "Bearer <scope-token>"},
        "enabledTools": ["task_show", ...]}}}

  Both keys were confirmed live: agy connects on `serverUrl` and sends the
  `headers` verbatim, and `enabledTools` really filters — a server advertising
  `probe_ping` and `probe_hidden` with `"enabledTools": ["probe_ping"]` left agy
  seeing only `probe_ping`.

  The tool allowlist is a *secondary* scope hook in either CLI — the server
  enforces the worker's capability via the signed token; the client-side list
  just keeps the agent's tool menu to what the token permits, so
  most-restrictive-wins. Coordinator-scope callers may pass `include_tools: nil`
  to omit it.
  """

  @behaviour Arbiter.MCP.AgentConfig

  @dirname ".gemini"
  @filename "settings.json"

  # The worker-tier tool allowlist. Matches the tools that a :worker scope
  # token is permitted to call (see Arbiter.MCP.Scope and the tool catalog in
  # docs/mcp-server-design.md §3).
  @worker_tools ~w(
    task_show
    task_update_progress
    inbox_check
    message_send
    notify_list
    workspace_show
  )

  @doc """
  Write the Gemini-family MCP config into `worktree`.

  Routes on `cli_flavour/1`:

    * `:gemini` — writes `.gemini/settings.json`, the upstream CLI's
      project-scoped settings file.
    * `:agy` — returns `{:error, :unsupported}`. agy reads MCP config only from
      `$HOME`; no worktree-local path exists (see the moduledoc's probe). This
      is a deliberate, loud refusal so the failure is visible at dispatch rather
      than showing up later as an agy worker mysteriously lacking tools.

  Pass `cli: :agy | :gemini` to override PATH sniffing (tests, and any caller
  that already knows which binary it is about to spawn).
  """
  @impl true
  def write_mcp_config(worktree, opts) when is_binary(worktree) do
    case cli_flavour(opts) do
      :agy ->
        {:error, :unsupported}

      :gemini ->
        dir = Path.join(worktree, @dirname)

        with :ok <- File.mkdir_p(dir) do
          File.write(Path.join(dir, @filename), Jason.encode!(config_map(opts), pretty: true))
        end
    end
  end

  @doc """
  Which Gemini-family CLI this config is being written for.

  `opts[:cli]` wins when it is `:agy` or `:gemini`; otherwise the answer comes
  from `Arbiter.Agents.Gemini.resolve_executable/0`, which prefers `agy` when
  both binaries are on `PATH` — i.e. the same resolution the spawn itself will
  do. With neither CLI installed the dispatch cannot run anyway, so the
  historical `:gemini` default is kept.
  """
  @spec cli_flavour(keyword()) :: :agy | :gemini
  def cli_flavour(opts \\ []) do
    case Keyword.get(opts, :cli) do
      flavour when flavour in [:agy, :gemini] ->
        flavour

      _ ->
        case Arbiter.Agents.Gemini.resolve_executable() do
          {:ok, {:agy, _path}} -> :agy
          _ -> :gemini
        end
    end
  end

  @doc """
  The upstream `gemini` CLI's `.gemini/settings.json` content as a
  (string-keyed) map. Exposed for tests / inspection.

  Requires `:mcp_url` and `:scope_token`. Optional:
  - `:server_name` — defaults to `"arbiter"`.
  - `:include_tools` — a list of tool names to allowlist, or `:worker` (the
    default) to use the built-in worker-tier list, or `nil` to omit the key
    entirely (coordinator scope where all tools are permitted).
  """
  @spec config_map(keyword()) :: map()
  def config_map(opts) do
    server_map(opts, "httpUrl", "includeTools")
  end

  @doc """
  The `agy` (Antigravity) CLI's `mcp_config.json` content as a (string-keyed)
  map — `serverUrl` and `enabledTools`, not the upstream CLI's `httpUrl` /
  `includeTools`.

  Takes the same options as `config_map/1`. Note that agy has **no** path inside
  a worktree that it reads this from (see the moduledoc); this exists so that
  whatever gives an agy worker its own `HOME` can drop it at
  `<home>/.gemini/config/mcp_config.json` without re-deriving the schema.
  """
  @spec agy_config_map(keyword()) :: map()
  def agy_config_map(opts) do
    server_map(opts, "serverUrl", "enabledTools")
  end

  @doc "The worker-tier tool allowlist written into `includeTools` / `enabledTools`."
  @spec worker_tools() :: [String.t()]
  def worker_tools, do: @worker_tools

  @doc "The config directory name written into the worktree for the upstream `gemini` CLI (`.gemini`)."
  @spec dirname() :: String.t()
  def dirname, do: @dirname

  @doc "The config filename within the `.gemini` directory (`settings.json`)."
  @spec filename() :: String.t()
  def filename, do: @filename

  @doc "Patterns to add to `.git/info/exclude` so `git add -A` never stages this directory."
  @spec gitignore_paths() :: [String.t()]
  def gitignore_paths, do: [@dirname <> "/"]

  # ---- Internals -----------------------------------------------------------

  defp server_map(opts, url_key, tools_key) do
    url = Keyword.fetch!(opts, :mcp_url)
    token = Keyword.fetch!(opts, :scope_token)
    name = Keyword.get(opts, :server_name, "arbiter")

    server =
      %{
        url_key => url,
        "headers" => %{"Authorization" => "Bearer " <> token}
      }
      |> maybe_put_tools(tools_key, resolve_include_tools(opts))

    %{"mcpServers" => %{name => server}}
  end

  # :worker (default) → the built-in worker tool list
  # nil → omit the allowlist key entirely (coordinator scope)
  # a list → use as-is
  defp resolve_include_tools(opts) do
    case Keyword.get(opts, :include_tools, :worker) do
      :worker -> @worker_tools
      nil -> nil
      tools when is_list(tools) -> tools
    end
  end

  defp maybe_put_tools(server, _key, nil), do: server
  defp maybe_put_tools(server, key, tools), do: Map.put(server, key, tools)
end
