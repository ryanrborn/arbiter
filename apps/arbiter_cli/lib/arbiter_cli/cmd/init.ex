defmodule ArbiterCli.Cmd.Init do
  @moduledoc """
  `arb init [path] [--force]` — scaffold a coordinator home base.

  A fresh Arbiter adopter has no coordinator working folder. This command
  pre-seeds one — pre-filled for *this* install — so a new session has role
  instructions, a memory index, and a notes drop the moment it starts.

  Creates, in the target directory (default: cwd):

    * `AGENTS.md`              — the coordinator role doc: session-start
                                 checklist (`arb doctor` / `arb prime`), the
                                 arb command reference, core concepts, and
                                 memory discipline. Rendered with this
                                 install's domain and host. Contains NO
                                 persona — that is the operator's private
                                 layer.
    * `ARBITER_OPERATOR.md`    — the operator field guide: hard-won operating
                                 knowledge (concurrency discipline, config
                                 safety, deploy protocol, trust-but-verify
                                 patterns). Generic and transferable; edit
                                 freely.
    * `memory/MEMORY.md`       — a clean memory index skeleton (and an
                                 otherwise empty `memory/` dir).
    * `notes/README.md`        — explains the surface-to-operator drop.
    * `AGENTS.local.md`        — a stub personal overlay (gitignored, never
                                 committed); the operator fills it with
                                 persona / local identity.
    * `.gitignore`             — ignores `AGENTS.local.md`.

  The generated docs use the plain code terms (coordinator, worker, issue,
  repo, workspace) directly.

  Non-destructive: existing files are skipped and reported. Pass `--force`
  to overwrite them.

  ## Templating

  Templates are shipped in `priv/templates/*.eex` and compiled into this
  module at build time (so the escript carries them with no runtime file
  access). They are rendered with runtime values:

    * dashboard / host URL (`ARB_HOST`, default `http://127.0.0.1:4848`)
    * active domain name + prefix (from `Workspace.resolve/0`)
    * an Arbiter install-path hint (`ARB_HOME`, else best-effort)

  When the server is unreachable the command still scaffolds, falling back
  to a generic install-path hint.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  require EEx

  @templates_dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "templates"]))

  @agents_md Path.join(@templates_dir, "AGENTS.md.eex")
  @operator_guide Path.join(@templates_dir, "OPERATOR_FIELD_GUIDE.md.eex")
  @memory_md Path.join(@templates_dir, "MEMORY.md.eex")
  @notes_readme Path.join(@templates_dir, "notes_README.md.eex")
  @agents_local Path.join(@templates_dir, "AGENTS.local.md.eex")
  @gitignore Path.join(@templates_dir, "gitignore.eex")

  @external_resource @agents_md
  @external_resource @operator_guide
  @external_resource @memory_md
  @external_resource @notes_readme
  @external_resource @agents_local
  @external_resource @gitignore

  EEx.function_from_file(:defp, :render_agents_md, @agents_md, [:assigns])
  EEx.function_from_file(:defp, :render_operator_guide, @operator_guide, [:assigns])
  EEx.function_from_file(:defp, :render_memory_md, @memory_md, [:assigns])
  EEx.function_from_file(:defp, :render_notes_readme, @notes_readme, [:assigns])
  EEx.function_from_file(:defp, :render_agents_local, @agents_local, [:assigns])

  # The .gitignore template takes no runtime values — embed it verbatim at
  # compile time rather than running it through EEx with an unused binding.
  @gitignore_contents File.read!(@gitignore)
  defp render_gitignore(_assigns), do: @gitignore_contents

  @switches [force: :boolean, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      force = opts[:force] || false

      dir =
        case rest do
          [d | _] -> Path.expand(d)
          [] -> File.cwd!()
        end

      assigns = build_assigns()

      results =
        [
          {"AGENTS.md", render_agents_md(assigns)},
          {"ARBITER_OPERATOR.md", render_operator_guide(assigns)},
          {"AGENTS.local.md", render_agents_local(assigns)},
          {".gitignore", render_gitignore(assigns)},
          {"memory/MEMORY.md", render_memory_md(assigns)},
          {"notes/README.md", render_notes_readme(assigns)}
        ]
        |> Enum.map(fn {rel, contents} ->
          {rel, scaffold_file(Path.join(dir, rel), contents, force)}
        end)

      case mode do
        :json -> emit_json(dir, assigns, results)
        :text -> emit_text(dir, assigns, results)
      end
    end
  end

  # ---- scaffold ----------------------------------------------------------

  # Non-destructive by default: an existing file is left untouched unless
  # `force` is set. Parent dirs are created as needed, which is also how the
  # empty `memory/` and `notes/` dirs come into being.
  defp scaffold_file(path, contents, force) do
    exists = File.exists?(path)

    cond do
      exists and not force ->
        :skipped

      true ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
        if exists, do: :overwritten, else: :created
    end
  end

  # ---- runtime values ----------------------------------------------------

  defp build_assigns do
    {domain_name, domain_prefix} = resolve_domain()

    %{
      coordinator: "coordinator",
      coordinator_cap: "Coordinator",
      worker: "worker",
      worker_cap: "Worker",
      worker_plural: "workers",
      worker_plural_cap: "Workers",
      worker_article: "a",
      issue: "issue",
      issue_cap: "Issue",
      issue_article: "an",
      issue_plural: "issues",
      issue_plural_cap: "Issues",
      epic_cap: "Epic",
      repo: "repo",
      repo_cap: "Repo",
      repo_plural: "repos",
      workspace: "workspace",
      workspace_cap: "Workspace",
      host: Client.base_url(),
      domain_name: domain_name,
      domain_prefix: domain_prefix,
      install_path: install_hint()
    }
  end

  defp resolve_domain do
    case Workspace.resolve() do
      {:ok, ws} -> {ws["name"] || "default", ws["prefix"] || "bd"}
      {:error, _} -> {"default", "bd"}
    end
  end

  # Best-effort Arbiter checkout path for the "Starting the server" section.
  # `ARB_HOME` is the explicit override; otherwise we try to infer the
  # umbrella root from the running escript's path. Falls back to a clearly
  # marked placeholder the operator can edit.
  defp install_hint do
    System.get_env("ARB_HOME") || escript_umbrella() || "<path to your Arbiter checkout>"
  end

  defp escript_umbrella do
    :escript.script_name()
    |> to_string()
    |> Path.expand()
    |> derive_umbrella()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # The escript is built as `<umbrella>/apps/arbiter_cli/arb`. When run from
  # the build tree we can recover the umbrella root; an installed-on-PATH copy
  # tells us nothing useful, so we decline rather than guess.
  # File.exists? guards against false positives when `arb` is a short PATH name
  # invoked from a directory whose path ends with `/apps/arbiter_cli`.
  defp derive_umbrella(path) do
    if String.ends_with?(path, "/apps/arbiter_cli/arb") and File.exists?(path) do
      path |> Path.dirname() |> Path.dirname() |> Path.dirname()
    end
  end

  # ---- output ------------------------------------------------------------

  defp emit_text(dir, assigns, results) do
    IO.puts("arb init — coordinator home base in #{dir}")
    IO.puts("")

    Enum.each(results, fn {rel, status} ->
      IO.puts("  #{status_word(status)}  #{rel}#{skip_hint(status)}")
    end)

    IO.puts("")

    IO.puts(
      "terms: coordinator=#{assigns.coordinator} worker=#{assigns.worker} " <>
        "issue=#{assigns.issue}  (#{assigns.workspace}: #{assigns.domain_name}/#{assigns.domain_prefix})"
    )

    if Enum.any?(results, fn {_, s} -> s == :skipped end) do
      IO.puts("re-run with --force to overwrite skipped files.")
    end

    IO.puts("next: cd #{dir} && arb doctor && arb prime")
  end

  defp emit_json(dir, assigns, results) do
    payload = %{
      dir: dir,
      terms: %{
        coordinator: assigns.coordinator,
        worker: assigns.worker,
        issue: assigns.issue,
        workspace: assigns.workspace
      },
      domain: %{name: assigns.domain_name, prefix: assigns.domain_prefix},
      host: assigns.host,
      files: Enum.map(results, fn {rel, status} -> %{path: rel, status: status} end)
    }

    IO.puts(Jason.encode!(payload))
  end

  defp status_word(:created), do: "created    "
  defp status_word(:overwritten), do: "overwritten"
  defp status_word(:skipped), do: "skipped    "

  defp skip_hint(:skipped), do: "  (exists)"
  defp skip_hint(_), do: ""
end
