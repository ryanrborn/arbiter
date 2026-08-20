defmodule ArbiterCli.Cmd.Config do
  @moduledoc """
  `arb config` — safe, field-level access to a workspace's `config` JSON.

      arb config get      [dotted.key] [--workspace W] [--json]
      arb config set      <dotted.key> <value> [--workspace W] [--force]
      arb config unset    <dotted.key>         [--workspace W] [--force]
      arb config overview                       [--workspace W] [--json]
      arb config schema                         full config key reference

  `schema` prints a comprehensive reference of every top-level config key
  (tracker, merge, agent/review_agent, security, routing, review/review_gate,
  review_automation, quota, conductor, standing_orders, repo_paths, pr_patrol,
  review_patrol) with its sub-fields, valid enum values, and defaults — see
  `ArbiterCli.ConfigSchema` for the full text (also appended below).

  `overview` prints a human-readable summary of the workspace's config grouped
  into sections (tracker, merge, agent, routing, review, standing orders)
  rather than the raw JSON blob `get` emits. Secret *values* are never shown —
  only the names of configured secrets and any `credentials_ref` pointers.

  ## Background

  Until this command, the only ways to change config were `PATCH /api/workspaces/:id`
  (replace-the-whole-map semantics — a partial patch silently clobbered sibling
  keys) or raw SQL. `arb config set` and `arb config unset` go through
  `PATCH /api/workspaces/:id/config`, which **deep-merges** into the existing
  config so siblings are preserved.

  ## Value parsing

  `arb config set <key> <value>` parses the value in this order:

    * `true` / `false`                → boolean
    * an integer literal              → integer
    * starts with `{` or `[`          → JSON (object or array)
    * the literal string `null`       → JSON null (use `unset` to actually remove)
    * anything else                   → string

  Quote shell-special values to keep them out of the parser's hands
  (`arb config set tracker.config.host '"x.example.com"'`).

  ## Guardrails

  Before sending a `set` or `unset`, the CLI computes the local before/after
  and refuses (without `--force`) any change that would drop required keys:

    * empty `repo_paths` (when `repo_paths` exists and would become `{}`)
    * `tracker.type != "none"` with `tracker.config` missing or empty
    * `merge.strategy == "github"` — no static check (owner + repo are per-repo derivable)

  Destructive changes (any unset, or any set that overwrites a non-empty
  existing leaf) print a before/after diff. The server-side `ValidateConfig`
  check still runs on top.

  ## Workspace selection

  By default targets the workspace resolved from `ARB_WORKSPACE` (or the one
  literally named `"default"`). Override per-invocation with
  `--workspace <name>`.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.Cmd.Config.{Formatter, Value}
  alias ArbiterCli.{Client, Output, Workspace}

  @switches [workspace: :string, force: :boolean, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
      IO.puts("")
      IO.puts(ArbiterCli.ConfigSchema.render())
    else
      {opts, rest, mode} = ArgParser.parse(argv, switches: @switches)
      workspace_opt = opts[:workspace]
      force = opts[:force] || false

      case rest do
        ["get" | rest] -> get(rest, workspace_opt, mode)
        ["set" | rest] -> set(rest, workspace_opt, force, mode)
        ["unset" | rest] -> unset(rest, workspace_opt, force, mode)
        ["overview" | _] -> overview(workspace_opt, mode)
        ["schema" | _] -> IO.puts(ArbiterCli.ConfigSchema.render())
        [] -> Output.die("config requires a subcommand: get, set, unset, overview, or schema")
        [unknown | _] -> Output.die("unknown config subcommand: #{unknown}")
      end
    end
  end

  # ----- get --------------------------------------------------------------

  defp get(args, workspace_opt, mode) do
    path =
      case args do
        [] -> nil
        [p] -> p
        _ -> Output.die("config get takes at most one positional argument: the dotted key")
      end

    ws = resolve_workspace!(workspace_opt)
    config = ws["config"] || %{}
    value = if path, do: Value.get_in_path(config, Value.split(path)), else: config

    case {mode, value} do
      {:json, v} -> Formatter.emit_get(:json, v)
      {:text, v} -> Formatter.emit_get(:text, v, path)
    end
  end

  # ----- overview ---------------------------------------------------------

  defp overview(workspace_opt, mode) do
    ws = resolve_workspace!(workspace_opt)
    config = ws["config"] || %{}
    Formatter.emit_overview(mode, ws, config)
  end

  # ----- set --------------------------------------------------------------

  defp set(args, workspace_opt, force, mode) do
    {key, raw_value} =
      case args do
        [k, v] -> {k, v}
        [k | rest] when rest != [] -> {k, Enum.join(rest, " ")}
        [_] -> Output.die("config set requires a value: arb config set <key> <value>")
        [] -> Output.die("config set requires <key> <value>")
      end

    path = Value.split(key)
    if path == [], do: Output.die("config set: key must not be empty")

    value = Value.parse_value(raw_value)
    patch = Value.put_in_path(%{}, path, value)

    ws = resolve_workspace!(workspace_opt)
    existing = ws["config"] || %{}
    new_config = Value.deep_merge(existing, patch)

    confirm_or_die!(existing, new_config, force, "set #{key}")

    payload = %{"patch" => patch}

    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} -> Formatter.emit_workspace_config(updated, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ----- unset ------------------------------------------------------------

  defp unset(args, workspace_opt, force, mode) do
    key =
      case args do
        [k] -> k
        [] -> Output.die("config unset requires a key: arb config unset <key>")
        _ -> Output.die("config unset takes exactly one argument: the dotted key")
      end

    path = Value.split(key)
    if path == [], do: Output.die("config unset: key must not be empty")

    ws = resolve_workspace!(workspace_opt)
    existing = ws["config"] || %{}

    if Value.get_in_path(existing, path) == nil do
      Output.die("config unset: key not found: #{key}")
    end

    new_config = Value.drop_path(existing, path)

    confirm_or_die!(existing, new_config, force, "unset #{key}")

    payload = %{"unset_paths" => [key]}

    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} -> Formatter.emit_workspace_config(updated, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ----- workspace resolution --------------------------------------------

  defp resolve_workspace!(nil) do
    case Workspace.resolve() do
      {:ok, ws} -> ws
      {:error, msg} -> Output.die(msg)
    end
  end

  defp resolve_workspace!(name) do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} ->
        case Enum.find(list, &(&1["name"] == name)) do
          nil -> Output.die("no workspace named #{inspect(name)}")
          ws -> ws
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  # ----- value parsing (public for tests) ---------------------------------

  @doc false
  defdelegate parse_value(raw), to: Value

  @doc false
  defdelegate split(path), to: Value

  @doc false
  defdelegate get_in_path(value, path), to: Value

  @doc false
  defdelegate put_in_path(map, path, value), to: Value

  @doc false
  defdelegate drop_path(map, path), to: Value

  @doc false
  defdelegate deep_merge(left, right), to: Value

  @doc """
  Returns `:ok` if the new config is "safe", or `{:unsafe, [reasons]}` if it
  drops a key the system relies on. Reasons mirror the task description.
  """
  defdelegate safety_check(new_config), to: Value

  # ----- guardrails + diff -----------------------------------------------

  defp confirm_or_die!(before, after_, force, label) do
    case Value.safety_check(after_) do
      :ok ->
        if destructive?(before, after_) and not force do
          IO.puts(:stderr, "arb config #{label}:")
          IO.puts(:stderr, Formatter.diff(before, after_))
          IO.puts(:stderr, "")
          IO.puts(:stderr, "this overwrites an existing value. Re-run with --force to apply.")
          Output.halt(1)
        else
          :ok
        end

      {:unsafe, reasons} ->
        if force do
          IO.puts(:stderr, "arb config #{label}: WARNING — proceeding under --force:")

          Enum.each(reasons, fn r -> IO.puts(:stderr, "  - " <> r) end)

          :ok
        else
          IO.puts(
            :stderr,
            "arb config #{label}: refusing — would leave config in a broken state:"
          )

          Enum.each(reasons, fn r -> IO.puts(:stderr, "  - " <> r) end)

          IO.puts(:stderr, "")
          IO.puts(:stderr, "Re-run with --force to override.")
          Output.halt(1)
        end
    end
  end

  defp destructive?(before, after_) do
    # A change is "destructive" if it removes a key that existed, or
    # overwrites a non-empty existing value with a different one.
    paths = collect_paths(before)

    Enum.any?(paths, fn p ->
      old = Value.get_in_path(before, p)
      new = Value.get_in_path(after_, p)

      cond do
        old in [nil, "", %{}, []] -> false
        new == old -> false
        new == nil -> true
        is_map(old) and is_map(new) -> false
        true -> true
      end
    end)
  end

  defp collect_paths(map, prefix \\ [])

  defp collect_paths(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      this = prefix ++ [to_string(k)]

      if is_map(v) and map_size(v) > 0 do
        [this | collect_paths(v, this)]
      else
        [this]
      end
    end)
  end

  defp collect_paths(_, _), do: []
end
