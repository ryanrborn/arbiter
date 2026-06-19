defmodule ArbiterCli.Cmd.Config do
  @moduledoc """
  `arb config` — safe, field-level access to a workspace's `config` JSON.

      arb config get   [dotted.key] [--workspace W] [--json]
      arb config set   <dotted.key> <value> [--workspace W] [--force]
      arb config unset <dotted.key>         [--workspace W] [--force]

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

  alias ArbiterCli.{Client, Output, Workspace}

  @switches [workspace: :string, force: :boolean, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      workspace_opt = opts[:workspace]
      force = opts[:force] || false

      case rest do
        ["get" | rest] -> get(rest, workspace_opt, mode)
        ["set" | rest] -> set(rest, workspace_opt, force, mode)
        ["unset" | rest] -> unset(rest, workspace_opt, force, mode)
        [] -> Output.die("config requires a subcommand: get, set, or unset")
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
    value = if path, do: get_in_path(config, split(path)), else: config

    case {mode, value} do
      {:json, v} ->
        IO.puts(Jason.encode!(v))

      {:text, nil} ->
        if path do
          Output.die("config: key not found: #{path}")
        else
          IO.puts("(empty)")
        end

      {:text, v} ->
        IO.puts(pretty(v))
    end
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

    path = split(key)
    if path == [], do: Output.die("config set: key must not be empty")

    value = parse_value(raw_value)
    patch = put_in_path(%{}, path, value)

    ws = resolve_workspace!(workspace_opt)
    existing = ws["config"] || %{}
    new_config = deep_merge(existing, patch)

    confirm_or_die!(existing, new_config, force, "set #{key}")

    payload = %{"patch" => patch}

    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} -> emit_workspace_config(updated, mode)
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

    path = split(key)
    if path == [], do: Output.die("config unset: key must not be empty")

    ws = resolve_workspace!(workspace_opt)
    existing = ws["config"] || %{}

    if get_in_path(existing, path) == nil do
      Output.die("config unset: key not found: #{key}")
    end

    new_config = drop_path(existing, path)

    confirm_or_die!(existing, new_config, force, "unset #{key}")

    payload = %{"unset_paths" => [key]}

    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} -> emit_workspace_config(updated, mode)
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

  # ----- value parsing ----------------------------------------------------

  @doc false
  def parse_value("true"), do: true
  def parse_value("false"), do: false

  def parse_value(raw) when is_binary(raw) do
    cond do
      String.match?(raw, ~r/^-?\d+$/) ->
        String.to_integer(raw)

      String.starts_with?(raw, "{") or String.starts_with?(raw, "[") ->
        case Jason.decode(raw) do
          {:ok, v} -> v
          {:error, _} -> raw
        end

      raw == "null" ->
        nil

      true ->
        raw
    end
  end

  # ----- dotted-path helpers ---------------------------------------------

  @doc false
  def split(path) when is_binary(path) do
    path |> String.split(".") |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def get_in_path(value, []), do: value

  def get_in_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil -> nil
      sub -> get_in_path(sub, rest)
    end
  end

  def get_in_path(_, _), do: nil

  @doc false
  def put_in_path(map, [k], value) when is_map(map), do: Map.put(map, k, value)

  def put_in_path(map, [k | rest], value) when is_map(map) do
    sub =
      case Map.get(map, k) do
        %{} = s -> s
        _ -> %{}
      end

    Map.put(map, k, put_in_path(sub, rest, value))
  end

  @doc false
  def drop_path(map, [k]) when is_map(map), do: Map.delete(map, k)

  def drop_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      %{} = sub -> Map.put(map, k, drop_path(sub, rest))
      _ -> map
    end
  end

  def drop_path(other, _), do: other

  @doc false
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  # ----- guardrails + diff -----------------------------------------------

  @doc """
  Returns `:ok` if the new config is "safe", or `{:unsafe, [reasons]}` if it
  drops a key the system relies on. Reasons mirror the bead description.
  """
  def safety_check(new_config) when is_map(new_config) do
    reasons =
      []
      |> check_repo_paths(new_config)
      |> check_tracker(new_config)
      |> check_github_merge(new_config)

    case reasons do
      [] -> :ok
      list -> {:unsafe, Enum.reverse(list)}
    end
  end

  defp check_repo_paths(reasons, config) do
    case Map.fetch(config, "repo_paths") do
      {:ok, m} when is_map(m) and map_size(m) == 0 ->
        ["repo_paths is empty — polecat dispatch cannot resolve a working dir" | reasons]

      _ ->
        case Map.fetch(config, "rig_paths") do
          {:ok, m} when is_map(m) and map_size(m) == 0 ->
            ["rig_paths is empty — polecat dispatch cannot resolve a working dir" | reasons]

          _ ->
            reasons
        end
    end
  end

  defp check_tracker(reasons, config) do
    case get_in_path(config, ["tracker"]) do
      %{"type" => type} = tracker when is_binary(type) and type != "none" ->
        case Map.get(tracker, "config") do
          c when is_map(c) and map_size(c) > 0 ->
            reasons

          _ ->
            ["tracker.type is #{inspect(type)} but tracker.config is missing/empty" | reasons]
        end

      _ ->
        reasons
    end
  end

  defp check_github_merge(reasons, _config) do
    # owner and repo are both per-repo derivable from the repo's origin remote
    # (Arbiter.Mergers.Github.RepoResolver). No static check needed here —
    # the runtime raises a clear error if credentials are missing.
    reasons
  end

  defp confirm_or_die!(before, after_, force, label) do
    case safety_check(after_) do
      :ok ->
        if destructive?(before, after_) and not force do
          IO.puts(:stderr, "arb config #{label}:")
          IO.puts(:stderr, diff(before, after_))
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
      old = get_in_path(before, p)
      new = get_in_path(after_, p)

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

  defp diff(before, after_) do
    "  before: " <> pretty_inline(before) <> "\n" <> "  after:  " <> pretty_inline(after_)
  end

  # ----- output -----------------------------------------------------------

  defp emit_workspace_config(updated, :json), do: IO.puts(Jason.encode!(updated["config"]))

  defp emit_workspace_config(updated, :text) do
    IO.puts("updated workspace " <> (updated["name"] || updated["id"]))
    IO.puts(pretty(updated["config"] || %{}))
  end

  defp pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, s} -> s
      {:error, _} -> inspect(value)
    end
  end

  defp pretty_inline(value) do
    case Jason.encode(value) do
      {:ok, s} -> s
      {:error, _} -> inspect(value)
    end
  end
end
