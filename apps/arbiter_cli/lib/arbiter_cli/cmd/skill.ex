defmodule ArbiterCli.Cmd.Skill do
  @moduledoc """
  `arb skill <verb>` — the system-wide skill registry (bd-cj6i08).

  A skill is a reusable markdown instruction module arbiter materializes into a
  worker's worktree at `.claude/skills/<name>/SKILL.md`. The registry is
  system-wide — one definition is shared across the whole arbiter system
  (NOT workspace-scoped).

      arb skill list                                registered skills (name + size + metadata)
      arb skill show   <id|name>                    one skill's full body + metadata
      arb skill create <name> [--body ... | --body-file PATH | -]
                                     [--metadata JSON] [--activation-mode situational|always_on]
                                     [--code-only]
      arb skill update <id|name> [--name NEW] [--body ... | --body-file PATH | -]
                                     [--metadata JSON] [--activation-mode situational|always_on]
                                     [--code-only]

  Activation (DECISION C, epic child 3): `--activation-mode always_on` makes
  arbiter auto-invoke `/<name>` in every worker prompt where the skill applies;
  `situational` (default) advertises it and leaves invocation to the agent.
  `--code-only` restricts the skill to code-producing tasks (feature/bug/chore),
  so an always-on code-discipline skill (TDD) never attaches to a decision /
  spike / doc task.
      arb skill delete <id|name> [--force]

  Body input for `create` / `update` comes from exactly one of:

    * `--body "<markdown>"`  — inline
    * `--body-file <path>`   — read from a file
    * `-`                    — read the body from stdin (paste, then Ctrl-D)

  A create/update whose `name` collides with a bundled skill (e.g. `code-review`)
  still succeeds but prints a warning — workers always see the built-in one too.

  All verbs go through the REST API at `/api/skills`.
  """

  alias ArbiterCli.{Client, Output}

  @switches [
    body: :string,
    body_file: :string,
    metadata: :string,
    name: :string,
    activation_mode: :string,
    code_only: :boolean,
    force: :boolean,
    json: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      case rest do
        ["list" | _] ->
          list(mode)

        ["ls" | _] ->
          list(mode)

        ["show" | args] ->
          show(args, mode)

        ["create" | args] ->
          create(args, opts, mode)

        ["update" | args] ->
          update(args, opts, mode)

        ["delete" | args] ->
          delete(args, opts, mode)

        ["rm" | args] ->
          delete(args, opts, mode)

        [] ->
          Output.die("skill requires a subcommand", "verbs: list, show, create, update, delete")

        [unknown | _] ->
          Output.die("unknown skill subcommand: #{unknown}")
      end
    end
  end

  # ---- list --------------------------------------------------------------

  defp list(mode) do
    case Client.get("/api/skills") do
      {:ok, %{"data" => skills}} -> emit_list(skills, mode)
      {:ok, _} -> emit_list([], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(skills, :json), do: IO.puts(Jason.encode!(%{data: skills}))

  defp emit_list([], :text), do: IO.puts("(no skills)")

  defp emit_list(skills, :text) do
    Enum.each(skills, fn s ->
      bytes = byte_size(s["body"] || "")
      desc = get_in(s, ["metadata", "description"])
      suffix = if desc in [nil, ""], do: "", else: "  — #{desc}"
      IO.puts("#{s["name"]}  (#{bytes} bytes)#{activation_tag(s)}#{suffix}")
    end)
  end

  # Compact activation/scope tag for the list view, e.g. " [always_on, code-only]".
  defp activation_tag(s) do
    tags =
      [
        s["activation_mode"],
        if(s["code_only"] == true, do: "code-only")
      ]
      |> Enum.reject(&(&1 in [nil, "", "situational"]))

    case tags do
      [] -> ""
      list -> "  [#{Enum.join(list, ", ")}]"
    end
  end

  # ---- show --------------------------------------------------------------

  defp show(args, mode) do
    ref = one_ref!(args, "show")

    case Client.get("/api/skills/" <> URI.encode(ref)) do
      {:ok, skill} -> emit_show(skill, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_show(skill, :json), do: IO.puts(Jason.encode!(skill))

  defp emit_show(skill, :text) do
    IO.puts("Name:       #{skill["name"]}")
    IO.puts("ID:         #{skill["id"]}")
    IO.puts("Activation: #{skill["activation_mode"] || "situational"}")
    IO.puts("Code-only:  #{skill["code_only"] == true}")

    metadata = skill["metadata"] || %{}

    unless metadata == %{} do
      IO.puts("Metadata:   #{Jason.encode!(metadata)}")
    end

    IO.puts("Updated:    #{skill["updated_at"]}")
    IO.puts("")
    IO.puts(skill["body"] || "")
  end

  # ---- create ------------------------------------------------------------

  defp create(args, opts, mode) do
    name = one_ref!(args, "create")
    body = resolve_body!(opts)
    metadata = parse_metadata!(opts[:metadata])

    payload =
      %{"name" => name, "body" => body}
      |> maybe_put("metadata", metadata)
      |> maybe_put("activation_mode", validate_activation!(opts[:activation_mode]))
      |> maybe_put("code_only", opts[:code_only])

    case Client.post("/api/skills", payload) do
      {:ok, skill} -> emit_written(skill, "created", mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- update ------------------------------------------------------------

  defp update(args, opts, mode) do
    ref = one_ref!(args, "update")

    payload =
      %{}
      |> maybe_put("name", opts[:name])
      |> maybe_put("body", resolve_body(opts))
      |> maybe_put("metadata", parse_metadata!(opts[:metadata]))
      |> maybe_put("activation_mode", validate_activation!(opts[:activation_mode]))
      |> maybe_put("code_only", opts[:code_only])

    if payload == %{} do
      Output.die(
        "skill update: nothing to change (pass --name, --body/--body-file/-, --metadata, " <>
          "--activation-mode, or --code-only)"
      )
    end

    case Client.patch("/api/skills/" <> URI.encode(ref), payload) do
      {:ok, skill} -> emit_written(skill, "updated", mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- delete ------------------------------------------------------------

  defp delete(args, opts, mode) do
    ref = one_ref!(args, "delete")

    unless opts[:force] do
      confirm!(ref)
    end

    case Client.delete("/api/skills/" <> URI.encode(ref)) do
      {:ok, skill} -> emit_deleted(skill, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp confirm!(ref) do
    answer = IO.gets("Delete skill #{inspect(ref)}? [y/N] ") |> to_string() |> String.trim()

    unless answer in ["y", "Y", "yes"] do
      IO.puts("aborted")
      Output.halt(0)
    end
  end

  defp emit_deleted(skill, :json), do: IO.puts(Jason.encode!(skill))
  defp emit_deleted(skill, :text), do: IO.puts("deleted skill #{skill["name"]}")

  # ---- output ------------------------------------------------------------

  defp emit_written(skill, _verb, :json), do: IO.puts(Jason.encode!(skill))

  defp emit_written(skill, verb, :text) do
    IO.puts("#{verb} skill #{skill["name"]}")

    case skill["warning"] do
      w when is_binary(w) and w != "" -> IO.puts(:stderr, "warning: " <> w)
      _ -> :ok
    end
  end

  # ---- body / metadata resolution ---------------------------------------

  # Required body (create): exactly one source must be given.
  defp resolve_body!(opts) do
    case resolve_body(opts) do
      nil ->
        Output.die("skill create requires a body: pass --body, --body-file <path>, or - (stdin)")

      body ->
        body
    end
  end

  # Optional body (update): nil when no body source was given.
  defp resolve_body(opts) do
    cond do
      opts[:body] && opts[:body_file] ->
        Output.die("pass only one of --body / --body-file")

      is_binary(opts[:body]) ->
        opts[:body]

      is_binary(opts[:body_file]) ->
        case File.read(opts[:body_file]) do
          {:ok, contents} -> contents
          {:error, reason} -> Output.die("cannot read --body-file: #{:file.format_error(reason)}")
        end

      stdin_requested?() ->
        read_stdin()

      true ->
        nil
    end
  end

  # A bare `-` positional (after the ref) requests reading the body from stdin.
  defp stdin_requested?, do: "-" in System.argv()

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      :eof -> ""
      {:error, _} -> ""
      data -> data
    end
  end

  # `--activation-mode` accepts only the two known modes; anything else is a
  # usage error. nil (flag absent) passes through so the server default applies.
  defp validate_activation!(nil), do: nil

  defp validate_activation!(mode) when mode in ["situational", "always_on"], do: mode

  defp validate_activation!(other),
    do: Output.die("--activation-mode must be 'situational' or 'always_on', got #{inspect(other)}")

  defp parse_metadata!(nil), do: nil

  defp parse_metadata!(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      {:ok, _} -> Output.die("--metadata must be a JSON object")
      {:error, _} -> Output.die("--metadata must be valid JSON")
    end
  end

  # ---- helpers -----------------------------------------------------------

  # The single positional ref (name or id), ignoring a bare `-` (stdin marker).
  defp one_ref!(args, verb) do
    case Enum.reject(args, &(&1 == "-")) do
      [ref | _] -> ref
      [] -> Output.die("skill #{verb} requires a skill name or id")
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
