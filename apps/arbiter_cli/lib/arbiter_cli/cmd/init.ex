defmodule ArbiterCli.Cmd.Init do
  @moduledoc """
  `arb init [path] [--force] [--dev] [--diff]` — scaffold a coordinator home base.

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
    * `docs/*.md`              — situational runbooks (deploy, monitoring,
                                 quota/auth, worktrees, ReviewGate, PR patrol,
                                 external trackers) meant to be read on
                                 demand, not preloaded — `AGENTS.md` carries
                                 the index of when to reach for each.
    * `memory/MEMORY.md`       — a clean memory index skeleton (and an
                                 otherwise empty `memory/` dir).
    * `notes/README.md`        — explains the surface-to-operator drop.
    * `runbooks/arbiter-event-monitor.md` — the canonical runbook for "the
                                 arbiter event monitor": the live `/events`
                                 NDJSON tail, disambiguated from the internal
                                 `monitor` runtime component and the generic
                                 "Monitor" operator step.
    * `AGENTS.local.md`        — a stub personal overlay (gitignored, never
                                 committed); the operator fills it with
                                 persona / local identity.
    * `.gitignore`             — ignores `AGENTS.local.md`.

  The generated docs use the plain code terms (coordinator, worker, issue,
  repo, workspace) directly.

  Non-destructive: existing files are skipped and reported. Pass `--force`
  to overwrite them.

  ## Reconciling with an already-scaffolded dir

  Pass `--diff` instead of scaffolding: renders the current templates and
  `diff -u`s each against whatever's on disk in the target dir, printing the
  hunks per file (or "new upstream file, not present locally" for a file
  that doesn't exist yet). Writes nothing — it's strictly a report for the
  operator (or coordinator session) to hand-review and cherry-pick from, the
  same way any diff gets reviewed. `--json --diff` emits the same
  `{path, status}` shape as plain `--json`, plus a `diff` field (unified
  diff text, or `null` when unchanged/new). `.mcp.json` is excluded from
  the comparison (reported as `not_comparable`, `diff: null`) since it
  holds a minted coordinator bearer token, not template content — diffing
  it would only ever report install-local token churn, and would print a
  live credential.

  ## Install topology

  By default the generated "Starting the server" section assumes a
  **production install**: a systemd user service running a prebuilt OTP
  release (`arb install-service` / `systemctl --user`). Pass `--dev` when
  this install is a source checkout dogfooding Arbiter itself — that
  renders `mix phx.server` instructions instead.

  ## Templating

  Templates are shipped in `priv/templates/*.eex` (and `priv/templates/docs/`
  for the runbooks) and compiled into this module at build time (so the
  escript carries them with no runtime file access). They are rendered with
  runtime values:

    * dashboard / host URL (`ARB_HOST`, default `http://127.0.0.1:4848`)
    * active domain name + prefix (from `Workspace.resolve/0`)
    * an Arbiter install-path hint (`ARB_HOME`, else best-effort) — used only
      in `--dev` mode
    * whether `--dev` was passed

  When the server is unreachable the command still scaffolds, falling back
  to a generic install-path hint.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  require EEx

  @templates_dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "templates"]))
  @docs_templates_dir Path.join(@templates_dir, "docs")

  @agents_md Path.join(@templates_dir, "AGENTS.md.eex")
  @operator_guide Path.join(@templates_dir, "OPERATOR_FIELD_GUIDE.md.eex")
  @memory_md Path.join(@templates_dir, "MEMORY.md.eex")
  @notes_readme Path.join(@templates_dir, "notes_README.md.eex")
  @agents_local Path.join(@templates_dir, "AGENTS.local.md.eex")
  @gitignore Path.join(@templates_dir, "gitignore.eex")
  @mcp_json Path.join(@templates_dir, "mcp_json.eex")

  @runbooks_templates_dir Path.join(@templates_dir, "runbooks")
  @runbook_event_monitor Path.join(@runbooks_templates_dir, "arbiter-event-monitor.md.eex")

  @doc_deploy Path.join(@docs_templates_dir, "deploy.md.eex")
  @doc_monitoring Path.join(@docs_templates_dir, "monitoring.md.eex")
  @doc_quota_and_auth Path.join(@docs_templates_dir, "quota-and-auth.md.eex")
  @doc_worktrees_and_workers Path.join(@docs_templates_dir, "worktrees-and-workers.md.eex")
  @doc_reviewgate Path.join(@docs_templates_dir, "reviewgate.md.eex")
  @doc_pr_patrol Path.join(@docs_templates_dir, "pr-patrol.md.eex")
  @doc_external_trackers Path.join(@docs_templates_dir, "external-trackers.md.eex")

  @external_resource @agents_md
  @external_resource @operator_guide
  @external_resource @memory_md
  @external_resource @notes_readme
  @external_resource @agents_local
  @external_resource @gitignore
  @external_resource @mcp_json
  @external_resource @doc_deploy
  @external_resource @doc_monitoring
  @external_resource @doc_quota_and_auth
  @external_resource @doc_worktrees_and_workers
  @external_resource @doc_reviewgate
  @external_resource @doc_pr_patrol
  @external_resource @doc_external_trackers
  @external_resource @runbook_event_monitor

  EEx.function_from_file(:defp, :render_agents_md, @agents_md, [:assigns])
  EEx.function_from_file(:defp, :render_operator_guide, @operator_guide, [:assigns])
  EEx.function_from_file(:defp, :render_memory_md, @memory_md, [:assigns])
  EEx.function_from_file(:defp, :render_notes_readme, @notes_readme, [:assigns])
  EEx.function_from_file(:defp, :render_agents_local, @agents_local, [:assigns])
  EEx.function_from_file(:defp, :render_mcp_json, @mcp_json, [:assigns])

  EEx.function_from_file(:defp, :render_doc_deploy, @doc_deploy, [:assigns])
  EEx.function_from_file(:defp, :render_doc_monitoring, @doc_monitoring, [:assigns])
  EEx.function_from_file(:defp, :render_doc_quota_and_auth, @doc_quota_and_auth, [:assigns])

  EEx.function_from_file(:defp, :render_doc_worktrees_and_workers, @doc_worktrees_and_workers, [
    :assigns
  ])

  EEx.function_from_file(:defp, :render_doc_reviewgate, @doc_reviewgate, [:assigns])
  EEx.function_from_file(:defp, :render_doc_pr_patrol, @doc_pr_patrol, [:assigns])
  EEx.function_from_file(:defp, :render_doc_external_trackers, @doc_external_trackers, [:assigns])

  EEx.function_from_file(:defp, :render_runbook_event_monitor, @runbook_event_monitor, [:assigns])

  # The .gitignore template takes no runtime values — embed it verbatim at
  # compile time rather than running it through EEx with an unused binding.
  @gitignore_contents File.read!(@gitignore)
  defp render_gitignore(_assigns), do: @gitignore_contents

  @switches [force: :boolean, json: :boolean, dev: :boolean, diff: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text
      force = opts[:force] || false
      dev_mode = opts[:dev] || false
      diff_mode = opts[:diff] || false

      dir =
        case rest do
          [d | _] -> Path.expand(d)
          [] -> File.cwd!()
        end

      assigns = build_assigns(dev_mode, diff_mode)
      templated_files = templated_files(assigns)

      if diff_mode do
        results =
          Enum.map(templated_files, fn
            {".mcp.json" = rel, _contents} ->
              {rel, {:not_comparable, nil}}

            {rel, contents} ->
              {rel, diff_file(Path.join(dir, rel), contents)}
          end)

        case mode do
          :json -> emit_diff_json(dir, assigns, results)
          :text -> emit_diff_text(dir, results)
        end
      else
        results =
          Enum.map(templated_files, fn {rel, contents} ->
            {rel, scaffold_file(Path.join(dir, rel), contents, force)}
          end)

        case mode do
          :json -> emit_json(dir, assigns, results)
          :text -> emit_text(dir, assigns, results)
        end
      end
    end
  end

  defp templated_files(assigns) do
    [
      {"AGENTS.md", render_agents_md(assigns)},
      {"ARBITER_OPERATOR.md", render_operator_guide(assigns)},
      {"AGENTS.local.md", render_agents_local(assigns)},
      {".gitignore", render_gitignore(assigns)},
      {".mcp.json", render_mcp_json(assigns)},
      {"memory/MEMORY.md", render_memory_md(assigns)},
      {"notes/README.md", render_notes_readme(assigns)},
      {"runbooks/arbiter-event-monitor.md", render_runbook_event_monitor(assigns)},
      {"docs/deploy.md", render_doc_deploy(assigns)},
      {"docs/monitoring.md", render_doc_monitoring(assigns)},
      {"docs/quota-and-auth.md", render_doc_quota_and_auth(assigns)},
      {"docs/worktrees-and-workers.md", render_doc_worktrees_and_workers(assigns)},
      {"docs/reviewgate.md", render_doc_reviewgate(assigns)},
      {"docs/pr-patrol.md", render_doc_pr_patrol(assigns)},
      {"docs/external-trackers.md", render_doc_external_trackers(assigns)}
    ]
  end

  # ---- scaffold ----------------------------------------------------------

  # Non-destructive by default: an existing file is left untouched unless
  # `force` is set. Parent dirs are created as needed, which is also how the
  # empty `memory/` and `notes/` dirs come into being.
  defp scaffold_file(path, contents, force) do
    exists = File.exists?(path)

    if exists and not force do
      :skipped
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      if exists, do: :overwritten, else: :created
    end
  end

  # ---- diff ---------------------------------------------------------------

  # Compares the current template's rendered output against whatever's on
  # disk at `path`, writing nothing. Returns `{:new, nil}` when the file
  # doesn't exist locally yet, `{:unchanged, nil}` when the disk copy matches
  # the current template exactly, or `{:diff, unified_diff_text}`.
  #
  # `.mcp.json` is never passed here: it holds a minted coordinator bearer
  # token, so "template drift" isn't a meaningful concept for it (every
  # install's token differs from the placeholder and from every other
  # install's) and diffing it would print a live credential to stdout/JSON.
  # Callers report it as `{:not_comparable, nil}` instead.
  defp diff_file(path, rendered_contents) do
    if File.exists?(path) do
      local_contents = File.read!(path)

      if local_contents == rendered_contents do
        {:unchanged, nil}
      else
        {:diff, unified_diff(rendered_contents, local_contents)}
      end
    else
      {:new, nil}
    end
  end

  # Shells out to `diff -u` rather than reimplementing a unified-diff
  # formatter. `System.cmd/3` has no stdin-piping option, so both sides get
  # scratch files even though the local copy is already on disk. The scratch
  # dir is mode 0700 (not the shared, world-readable `/tmp` default) since a
  # diffed file's on-disk contents may include local secrets, and the files
  # are always cleaned up — even if `diff` itself is missing from `PATH` or
  # `System.cmd/3` otherwise raises.
  defp unified_diff(rendered_contents, local_contents) do
    unique = Integer.to_string(System.unique_integer([:positive]))
    scratch_dir = Path.join(System.tmp_dir!(), "arb_init_diff_" <> unique)
    rendered_path = Path.join(scratch_dir, "template")
    local_path = Path.join(scratch_dir, "local")

    File.mkdir_p!(scratch_dir)
    File.chmod!(scratch_dir, 0o700)
    File.write!(rendered_path, rendered_contents)
    File.write!(local_path, local_contents)
    File.chmod!(rendered_path, 0o600)
    File.chmod!(local_path, 0o600)

    try do
      {out, _status} =
        System.cmd(
          "diff",
          ["-u", "--label", "template", "--label", "local", rendered_path, local_path],
          stderr_to_stdout: true
        )

      out
    rescue
      e in ErlangError ->
        File.rm_rf(scratch_dir)

        if e.original == :enoent do
          Output.die("`diff` is required for `arb init --diff` but was not found on PATH.")
        else
          Output.die("Failed to run `diff`: #{Exception.message(e)}")
        end
    after
      File.rm_rf(scratch_dir)
    end
  end

  # ---- runtime values ----------------------------------------------------

  # `diff_mode?` skips minting a real coordinator token: `--diff` is a
  # read-only report and must not mutate server state (or produce a diff
  # on .mcp.json that's just token churn from run to run).
  defp build_assigns(dev_mode, diff_mode?) do
    {domain_name, domain_prefix} = resolve_domain()
    base_url = Client.base_url()
    mcp_url = base_url <> "/mcp"

    %{
      dev_mode: dev_mode,
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
      host: base_url,
      domain_name: domain_name,
      domain_prefix: domain_prefix,
      install_path: install_hint(),
      mcp_url: mcp_url,
      coordinator_token:
        if(diff_mode?, do: "REPLACE_WITH_COORDINATOR_TOKEN", else: mint_coordinator_token())
    }
  end

  # Mint a long-lived coordinator-tier scope token for the MCP config.
  # Returns the token string on success, or a placeholder on failure (server
  # unreachable at init time). The operator can re-run `arb init --force` once
  # the server is up to replace the placeholder with a real token.
  defp mint_coordinator_token do
    # 30-day TTL — same as the CLI default for coordinator tokens.
    case Client.post("/api/mcp/tokens", %{"ttl" => 2_592_000}) do
      {:ok, %{"token" => token}} -> token
      _ -> "REPLACE_WITH_COORDINATOR_TOKEN"
    end
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

  defp emit_diff_text(dir, results) do
    IO.puts("arb init --diff — comparing current templates against #{dir}")
    IO.puts("")

    Enum.each(results, fn
      {rel, {:new, nil}} ->
        IO.puts("#{rel}: new upstream file, not present locally")
        IO.puts("")

      {rel, {:diff, diff_text}} ->
        IO.puts("#{rel}:")
        IO.puts(diff_text)
        IO.puts("")

      {_rel, {:unchanged, nil}} ->
        :ok

      {rel, {:not_comparable, nil}} ->
        IO.puts("#{rel}: not compared (install-local credential config)")
        IO.puts("")
    end)

    if Enum.all?(results, fn {_, {status, _}} -> status in [:unchanged, :not_comparable] end) do
      IO.puts("no template drift.")
    end
  end

  defp emit_diff_json(dir, assigns, results) do
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
      files:
        Enum.map(results, fn {rel, {status, diff_text}} ->
          %{path: rel, status: to_string(status), diff: diff_text}
        end)
    }

    IO.puts(Jason.encode!(payload))
  end

  defp status_word(:created), do: "created    "
  defp status_word(:overwritten), do: "overwritten"
  defp status_word(:skipped), do: "skipped    "

  defp skip_hint(:skipped), do: "  (exists)"
  defp skip_hint(_), do: ""
end
