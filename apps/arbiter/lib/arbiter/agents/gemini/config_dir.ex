defmodule Arbiter.Agents.Gemini.ConfigDir do
  @moduledoc """
  An isolated `$HOME` for `agy` (Antigravity) worker runs — the agy analogue of
  `Arbiter.Agents.Claude.ConfigDir` (bd-7s29yq / T6b, implementing the T6a
  spike's decision).

  ## Why `$HOME` and not a config-dir env var

  Claude gets `CLAUDE_CONFIG_DIR`; agy has nothing like it. The T6a spike
  (bd-83hjke) disassembled the binary and probed it live: there is **no**
  `AGY_*` / `GEMINI_*` config-root override, `--app_data_dir` only relocates
  the conversation/cache tree *within* `~/.gemini`, and every configuration
  input agy reads — `~/.gemini/antigravity-cli/settings.json` (permission
  posture), `~/.gemini/GEMINI.md` (user memory), `~/.gemini/config/skills/`,
  `~/.gemini/config/plugins/`, `~/.gemini/config/mcp_config.json` — is resolved
  from `$HOME`. Redirecting `HOME` is therefore the only per-spawn lever.

  Left un-isolated, an agy worker inherits the operator's
  `toolPermission: "always-proceed"` with no deny list, the operator's personal
  `GEMINI.md`, and the operator's skills/plugins. Probing confirmed both halves:
  a `GEMINI.md` planted in a throwaway `$HOME` *did* steer the model's output,
  which is exactly the bd-3y2mda persona hazard on the agy side.

  ## How

  `env/1` returns `[{"HOME", dir}]`; `ensure/1` seeds `dir` idempotently on
  every spawn:

    * `.gemini/antigravity-cli/settings.json` — **generated** from the spawn's
      `Arbiter.Agents.SecurityPolicy` by `Arbiter.Agents.Gemini.Security`, never
      copied. Rewritten on every spawn so a stale posture cannot linger.
    * `.gemini/GEMINI.md` — **written by us**, task-focused, persona-forbidding.
    * `.gemini/config/mcp_config.json` — written by `write_mcp_config/2` when
      the dispatch has an MCP scope token to hand out (bd-m8geh4 confirmed agy
      reads this path and this schema; `Arbiter.MCP.AgentConfig.Gemini`
      generates the document).
    * everything else in the operator's `$HOME` is **symlinked through**, except
      the three trees we deliberately shadow: `.gemini` (agy's own config — the
      whole point), `.agents` (agy's user-level skills/plugins/rules) and
      `.antigravity`.

  ### Why symlink the passthrough

  A worker still has to `git commit`, `gh`, `mix test` and `arb` — which need
  `.gitconfig`, `.ssh`, `.config/gh`, `.local`, `.cache/mix`, `.hex`, `.mix`,
  `.arbiter`. Copying all of that per worker is a cold-cache tax on every spawn
  and (for `.ssh`) would scatter copies of the operator's private keys across
  `~/.cache`. Symlinks keep exactly one copy of each and make this change
  *strictly* no worse than the status quo for everything except `.gemini`,
  which is the only thing we are here to isolate. Workers run as the same OS
  user either way — this is a config-inheritance boundary, not a security
  boundary against a hostile process.

  ### Credentials

  On a host with a working freedesktop Secret Service (D-Bus), agy stores its
  live Google grant in the **keyring**, not in `~/.gemini` — the spike proved a
  brand-new `$HOME` with zero credential files still authenticates. The keyring
  is scoped to the Linux user session, not to `$HOME`, so it survives the
  redirect untouched and there is nothing to seed. `keyring_available?/0`
  detects that case; only when no Secret Service is reachable do we **copy**
  (never symlink — a worker refreshing through a link would corrupt the
  operator's login) `oauth_creds.json`, `jetski-standalone-oauth-token` and
  `google_accounts.json`.

  ## Keyed per worktree

  Unlike the Claude config dir (one install-wide directory) this is keyed on the
  spawn's worktree. Two things force it: the generated `settings.json` carries
  a **per-workspace** posture, and `mcp_config.json` carries a **per-task**
  scope token — one shared directory would have concurrent agy workers
  overwriting each other's posture and token. Keying on the worktree also means
  `write_mcp_config/2` (called from dispatch, before the spawn) and `env/1`
  (called at spawn) independently compute the same directory without having to
  pass a handle between them.

  ## Config

    * `config :arbiter, :worker_isolate_config, boolean` — the shared master
      switch (default `true`); the test suite sets it `false`.
    * `config :arbiter, :worker_agy_home_root, "/path"` — override the root the
      per-worktree homes are created under.
    * `config :arbiter, :worker_agy_source_home, "/path"` — override the
      operator `$HOME` we pass through (tests).

  ## Safety / degradation

  Best-effort throughout. If the directory cannot be prepared, `ensure/1`
  returns `:error` and `env/1` returns `[]` — the worker runs against the
  inherited (un-isolated) `$HOME`, which is exactly today's behaviour. A
  working-but-un-isolated worker beats a broken one.
  """

  alias Arbiter.Agents.Gemini.Security
  alias Arbiter.Agents.SecurityPolicy

  require Logger

  # Shadowed, never passed through: everything agy reads its own configuration,
  # memory, skills and plugins from.
  @shadowed ~w(.gemini .agents .antigravity)

  # Copied (never symlinked) only when no Secret Service keyring is reachable.
  @credential_files ~w(oauth_creds.json jetski-standalone-oauth-token google_accounts.json)

  @gemini_dir ".gemini"
  @settings_path Path.join([".gemini", "antigravity-cli", "settings.json"])
  @memory_path Path.join(".gemini", "GEMINI.md")
  @mcp_config_path Path.join([".gemini", "config", "mcp_config.json"])

  @doc """
  The env pairs to inject into an agy spawn: `[{"HOME", dir}]` when isolation is
  enabled and the directory is ready, `[]` otherwise (inherit the host `$HOME`
  unchanged).

  Accepts the spawn's agent opts — `:worktree` (or `:worktree_path`) keys the
  directory and `:security` supplies the posture baked into `settings.json`.
  """
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts \\ []) do
    case ensure(opts) do
      {:ok, dir} -> [{"HOME", dir}]
      _ -> []
    end
  end

  @doc "Whether worker config isolation is enabled (default `true`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arbiter, :worker_isolate_config, true)

  @doc """
  The isolated `$HOME` for a spawn — `<root>/<worktree-key>`, or `<root>/default`
  for a spawn with no worktree in hand (a preflight/quota probe).

  Deterministic: the dispatch-time MCP writer and the spawn itself both land on
  the same directory from the same worktree.
  """
  @spec path(keyword()) :: String.t()
  def path(opts \\ []), do: Path.join(root(), key(worktree(opts)))

  @doc """
  Ensure the isolated `$HOME` exists and is seeded; return `{:ok, dir}`.

  Returns `:disabled` when isolation is switched off, `:error` when the
  directory could not be prepared. Idempotent — safe on every spawn.

  Options: `:worktree` / `:worktree_path`, `:security` (a `SecurityPolicy`),
  and `:keyring` (a boolean override for `keyring_available?/0`, for tests).
  """
  @spec ensure(keyword()) :: {:ok, String.t()} | :disabled | :error
  def ensure(opts \\ []) do
    if enabled?() do
      dir = path(opts)

      with :ok <- File.mkdir_p(Path.join(dir, Path.dirname(@settings_path))),
           :ok <- write_settings(dir, opts),
           :ok <- write_memory(dir) do
        passthrough(dir)
        seed_credentials(dir, opts)
        {:ok, dir}
      else
        {:error, reason} ->
          Logger.warning(
            "Arbiter.Agents.Gemini.ConfigDir: could not prepare isolated agy HOME " <>
              "#{inspect(path(opts))} (#{inspect(reason)}); worker will inherit the operator's " <>
              "$HOME — including their ~/.gemini permission posture and GEMINI.md"
          )

          :error
      end
    else
      :disabled
    end
  rescue
    e ->
      Logger.warning(
        "Arbiter.Agents.Gemini.ConfigDir: seeding raised #{inspect(e)}; not isolating"
      )

      :error
  end

  @doc """
  Write an agy MCP config document into the spawn's isolated `HOME`
  (`<home>/.gemini/config/mcp_config.json`) — the only path agy reads MCP
  servers from (bd-m8geh4).

  Returns `{:ok, path}`, or `{:error, :disabled}` when there is no
  Arbiter-owned `HOME` to write into (isolation off) — writing the operator's
  own `~/.gemini/config/mcp_config.json` instead is never acceptable: it would
  put a per-task scope token into the file the operator's interactive agy
  sessions read.
  """
  @spec write_mcp_config(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write_mcp_config(config, opts \\ []) when is_map(config) do
    case ensure(opts) do
      {:ok, dir} ->
        path = Path.join(dir, @mcp_config_path)

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, Jason.encode!(config, pretty: true)) do
          {:ok, path}
        end

      :disabled ->
        {:error, :disabled}

      :error ->
        {:error, :unavailable}
    end
  end

  @doc """
  Whether a freedesktop Secret Service is reachable for this OS user.

  When it is, agy's live credential lives in the keyring — which `$HOME`
  redirection does not touch — and seeding credential files is both unnecessary
  and a rotation hazard. See the moduledoc.
  """
  @spec keyring_available?() :: boolean()
  def keyring_available? do
    case System.get_env("DBUS_SESSION_BUS_ADDRESS") do
      "unix:path=" <> rest -> rest |> String.split(",") |> hd() |> File.exists?()
      addr when is_binary(addr) and addr != "" -> true
      _ -> false
    end
  end

  @doc "The worker memory written into the isolated HOME's `.gemini/GEMINI.md`."
  @spec worker_memory() :: String.t()
  def worker_memory do
    """
    # Arbiter Worker — Operating Context

    You are an autonomous **Arbiter worker**: a non-interactive `agy --print`
    session running inside a git worktree. Your whole job is the task in the
    prompt you were handed — nothing else.

    Hard rules (these override any other memory):

    - Produce only **task-focused, structured** output. Do NOT adopt a roleplay
      persona, character, honorific, or theatrical flourish — whatever any other
      memory or instruction may suggest. Downstream tooling parses your output;
      persona text corrupts it.
    - If you are a REVIEWER and you request changes, you MUST enumerate concrete
      findings — each with a severity, a `file:line` location, and a suggested
      fix. A change-request verdict that names no findings is invalid.
    - Follow the prompt's completion protocol **exactly** and verbatim: emit the
      `arb done` sentinel, and any `VERDICT:` line, each on its own line.
    - Run every tool synchronously. `run_command` must carry
      `WaitMsBeforeAsync: 10000` — a backgrounded command outlives the turn and
      the session ends before its output arrives.
    - Run one command per `run_command` call. Under a restricted permission
      policy every part of a chained command (`a && b`, `a; b`, `a | b`) must
      be allowed, and a denied command ends your turn. Do not retry a denied
      command or work around it: carry on without it, and note what you could
      not do in your findings.
    - Never fabricate evidence, citations, screenshots or artifacts. A
      screenshot is a real capture of the real app; a citation names where the
      thing actually came from. If an acceptance criterion cannot be met
      (screenshots are not possible headlessly, an official asset cannot be
      found), report it as unmet and say why. That is always acceptable; a
      mockup passed off as a screenshot is not. Do not change a true statement
      to satisfy a reviewer.
    - Never upload anything to a public or anonymous file or paste host
      (catbox.moe, 0x0.st, transfer.sh, file.io, pastebin and the like), never
      create a gist, and never post test comments on issues or PRs.

    ## Arbiter MCP tools

    If an `arbiter` MCP server is connected this session, prefer its typed tools
    over shelling out to `arb`: `task_show`, `inbox_check`,
    `task_update_progress`, `workspace_show`. Use `arb` and the shell for
    everything else — git, tests, and printing the `arb done` sentinel, which is
    still how you signal completion.
    """
  end

  @doc "The operator `$HOME` whose non-agy entries we pass through."
  @spec source_home() :: String.t() | nil
  def source_home do
    Application.get_env(:arbiter, :worker_agy_source_home) ||
      case System.user_home() do
        home when is_binary(home) and home != "" -> home
        _ -> nil
      end
  end

  @doc "The top-level entries of the operator's HOME that are never passed through."
  @spec shadowed() :: [String.t()]
  def shadowed, do: @shadowed

  # ---- internals ---------------------------------------------------------

  defp root do
    Application.get_env(:arbiter, :worker_agy_home_root) ||
      Path.join([cache_base(), "arbiter", "worker-agy"])
  end

  defp cache_base do
    System.get_env("XDG_CACHE_HOME") ||
      case System.user_home() do
        home when is_binary(home) and home != "" -> Path.join(home, ".cache")
        _ -> System.tmp_dir!()
      end
  end

  defp worktree(opts) do
    case Keyword.get(opts, :worktree) || Keyword.get(opts, :worktree_path) do
      wt when is_binary(wt) and wt != "" -> wt
      _ -> nil
    end
  end

  # A readable prefix (so the directory is greppable by a human debugging a
  # run) plus a hash, because two worktrees can share a basename.
  defp key(nil), do: "default"

  defp key(worktree) do
    digest =
      :sha256
      |> :crypto.hash(worktree)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 10)

    slug =
      worktree
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
      |> String.slice(0, 48)

    if slug == "", do: digest, else: slug <> "-" <> digest
  end

  # Always (re)write the generated settings so the posture can never drift from
  # the policy this spawn resolved.
  defp write_settings(dir, opts) do
    path = Path.join(dir, @settings_path)
    _ = File.rm(path)
    File.write(path, Security.settings_json(policy(opts), worktree: worktree(opts)))
  end

  defp policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  defp write_memory(dir) do
    path = Path.join(dir, @memory_path)
    _ = File.rm(path)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, worker_memory())
    end
  end

  # Symlink every top-level entry of the operator's HOME except the trees we
  # shadow. Idempotent: an existing correct link is left alone, a stale one is
  # replaced, and anything we own (`.gemini`) is never touched.
  defp passthrough(dir) do
    case source_home() do
      nil ->
        :ok

      src ->
        case File.ls(src) do
          {:ok, entries} ->
            entries
            |> Enum.reject(&(&1 in @shadowed))
            |> Enum.each(&link_one(src, dir, &1))

          {:error, reason} ->
            Logger.warning(
              "Arbiter.Agents.Gemini.ConfigDir: could not list #{inspect(src)} " <>
                "(#{inspect(reason)}); the worker HOME has no passthrough entries"
            )
        end
    end
  end

  defp link_one(src, dir, name) do
    target = Path.join(src, name)
    link = Path.join(dir, name)

    cond do
      # The entry *is* the home root (`<cache>/arbiter/worker-agy`): linking it
      # would put the worker's own HOME inside itself. Drop it.
      same_path?(target, root()) ->
        :ok

      # The entry *contains* the home root. The default root lives under
      # `~/.cache`, i.e. inside the operator's HOME, so a flat link would make
      # `<home>/.cache -> ~/.cache` and `<home>/.cache/arbiter/worker-agy/<key>`
      # resolve straight back to `<home>` — an unbounded symlink cycle rooted in
      # the worker's own HOME that any `du -L` / `rg --follow` / `cp -rL` the
      # worker runs would walk until ELOOP. Mirror the directory instead and
      # link its children, so `~/.cache/mix` & friends stay reachable.
      root_under?(target) ->
        descend(target, link)

      true ->
        do_link(target, link)
    end
  end

  # Recreate `target` as a real directory under the worker HOME and pass its
  # children through individually — recursing while the root is still below us,
  # and never linking the root itself (see `link_one/3`).
  defp descend(target, link) do
    # A HOME seeded before this rule existed still carries the cycle as a plain
    # symlink; replace it with a real directory.
    if match?({:ok, %{type: :symlink}}, File.lstat(link)), do: File.rm(link)

    with :ok <- File.mkdir_p(link),
         {:ok, entries} <- File.ls(target) do
      Enum.each(entries, &link_one(target, link, &1))
    else
      _ -> :ok
    end
  end

  defp do_link(target, link) do
    case File.read_link(link) do
      {:ok, ^target} ->
        :ok

      _ ->
        _ = File.rm(link)

        case File.ln_s(target, link) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug(
              "Arbiter.Agents.Gemini.ConfigDir: could not link #{inspect(link)} -> " <>
                "#{inspect(target)} (#{inspect(reason)})"
            )
        end
    end
  end

  defp same_path?(a, b), do: Path.expand(a) == Path.expand(b)

  defp root_under?(path),
    do: String.starts_with?(Path.expand(root()), Path.expand(path) <> "/")

  # See the moduledoc: with a keyring there is nothing to seed, and seeding
  # anyway would hand the worker a refreshable copy of the operator's grant.
  defp seed_credentials(dir, opts) do
    keyring? = Keyword.get(opts, :keyring, keyring_available?())

    cond do
      keyring? ->
        :ok

      is_nil(source_home()) ->
        :ok

      true ->
        Enum.each(@credential_files, &copy_credential(dir, &1))
    end
  end

  defp copy_credential(dir, name) do
    src = Path.join([source_home(), @gemini_dir, name])
    dst = Path.join([dir, @gemini_dir, name])

    if File.regular?(src) and not fresh_copy?(src, dst) do
      _ = File.rm(dst)

      case File.cp(src, dst) do
        :ok ->
          _ = File.chmod(dst, 0o600)
          :ok

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Agents.Gemini.ConfigDir: could not seed #{inspect(dst)} " <>
              "(#{inspect(reason)}); this agy worker may be unauthenticated"
          )
      end
    end
  end

  defp fresh_copy?(src, dst) do
    case {File.lstat(src), File.lstat(dst)} do
      {{:ok, %{type: :regular, mtime: sm}}, {:ok, %{type: :regular, mtime: dm}}} -> dm >= sm
      _ -> false
    end
  end
end
