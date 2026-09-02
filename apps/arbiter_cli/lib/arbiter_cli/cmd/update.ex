defmodule ArbiterCli.Cmd.Update do
  @moduledoc """
  `arb update` wears two hats, chosen by whether you name an issue.

  ## Deploy mode — `arb update [--timeout SECONDS] [--json]`

  With **no issue id**, `arb update` deploys freshly-merged work: it
  `git pull --ff-only`s the integration branch (`main`) in the Arbiter
  checkout, then runs an explicit deploy sequence: migrations → CLI escript
  rebuild (if changed) → Phoenix restart. One verb for the contributor +
  coordinator to ship merged work.

  Steps:

    1. **Locate the checkout** — the Arbiter project root (same resolution as
       `arb start`/`arb restart`: `ARB_HOME`, the escript's umbrella, or a
       walk up for `compose.yml`).
    2. **Refuse to clobber work.** Abort if the working tree is dirty, or if
       `HEAD` isn't on the integration branch — deploying is a fast-forward of
       `main`, never a merge or a branch switch under a running server.
    3. **`git pull --ff-only`.** A non-fast-forward (diverged history) makes
       git itself abort; we surface its message rather than force anything.
    4. **Report the short log** of the commits that arrived
       (`git log --oneline old..new`). If nothing arrived, say "already up to
       date" and exit — there's no new code to load.
    5. **Run database migrations** as an explicit step via `mix arbiter.migrate`,
       reporting how many migrations were applied (or 0 if the schema was already
       current). Migrations must succeed before proceeding.
    6. **Rebuild and install the CLI escript** if `apps/arbiter_cli` changed
       in the pulled commits. Detects changes via `git diff --name-only`, builds
       via `mix escript.build`, and installs to `~/.local/bin/arb`, making it
       executable. Skips rebuild if the CLI didn't change.
    7. **Restart Phoenix** via `ArbiterCli.Cmd.Restart.perform/2` to load the
       freshly-pulled code. Also re-runs the boot reconciler.

  ## Issue-edit mode — `arb update <id> [field flags]`

  With an **issue id**, `arb update` patches that issue's fields:

      arb update <id> [--priority N] [--append-notes text] [--status s]
                      [--description d] [--assignee a] [--acceptance a]
                      [--qa-notes text] [--deployment-notes text]
                      [--pr-body text] [--repo owner/name]

  `--acceptance` sets the acceptance criteria field, which guides the worker
  in implementing and testing the change.

  `--qa-notes` / `--deployment-notes` set the gated completion-notes fields
  a worker produces for tracker-backed work (QA Testing Notes / Deployment
  Notes on the Jira ticket). They overwrite the field (unlike `--append-notes`).

  `--repo` assigns the task to a repo (a configured `repo_paths` key). Every
  dispatch of the task then binds that repo, so a multi-repo workspace no longer
  needs `repo` passed per dispatch. An explicit `arb dispatch <id> <repo>` still
  overrides it for that one run.

  `--pr-body` sets the worker-authored PR/MR description the MergeQueue opens
  the task's single canonical PR with (Summary / Test plan / References). It
  overwrites the field.

  `--append-notes` appends the given string to the existing `notes` field
  (separated by two newlines). This requires fetching the issue first so we
  don't lose existing notes.

  ## Why one verb

  The two modes never collide: editing an issue *requires* an id, so any
  invocation with a positional argument is an edit, and a bare `arb update`
  (which previously just errored "requires an issue id") becomes the deploy.

  ## Exit codes

    * `0` — issue patched, or deploy succeeded (or was already up to date).
    * `1` — a bad invocation, an API error, a dirty/diverged checkout, or
      Phoenix not coming back green after the restart.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Client, Cmd.Migrate, Cmd.Restart, Cmd.Start, Output}
  alias ArbiterCli.Cmd.Update.{Formatter, Git}

  # The branch `arb update` fast-forwards. Matches the repo's integration
  # branch (`main`); a deploy is always a pull of merged work into it.
  @integration_branch "main"

  # Forwarded to the restart's green-wait. Mirrors `arb restart`'s default;
  # a cold `mix phx.server` may recompile, so it's generous.
  @default_timeout_s 60

  @edit_switches [
    priority: :integer,
    difficulty: :integer,
    append_notes: :string,
    notes: :string,
    acceptance: :string,
    qa_notes: :string,
    deployment_notes: :string,
    pr_body: :string,
    status: :string,
    description: :string,
    title: :string,
    assignee: :string,
    repo: :string,
    json: :boolean
  ]

  @deploy_switches [json: :boolean, timeout: :integer, force: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      if deploy_invocation?(argv) do
        deploy(argv)
      else
        edit_issue(argv)
      end
    end
  end

  @doc "Deploy mode (no issue id). Used by `arb server deploy`."
  @spec deploy([String.t()]) :: :ok | no_return()
  def deploy(argv) do
    if Output.help?(argv), do: IO.puts(@moduledoc), else: do_deploy(argv)
  end

  @doc "Issue-edit mode (requires an issue id). Used by `arb issue update <id>`."
  @spec edit_issue([String.t()]) :: :ok | no_return()
  def edit_issue(argv) do
    if Output.help?(argv), do: IO.puts(@moduledoc), else: do_edit_issue(argv)
  end

  # A bare verb, or one whose first token is a flag, is a deploy. The moment a
  # positional appears (the issue id) it's an edit — see the moduledoc.
  defp deploy_invocation?([]), do: true
  defp deploy_invocation?([first | _]), do: String.starts_with?(first, "-")

  # ---- deploy mode -------------------------------------------------------

  defp do_deploy(argv) do
    {opts, _rest, mode} =
      ArgParser.parse_strict!(argv, "arb update",
        strict: @deploy_switches,
        hint: fn flag ->
          "To deploy, run `arb update` with no issue id. To edit an issue, " <>
            "name it: `arb update <id> #{flag} …`."
        end
      )

    timeout_ms = max(1, opts[:timeout] || @default_timeout_s) * 1000
    force = opts[:force] || false

    root =
      case Start.project_root() do
        {:ok, dir} ->
          dir

        :error ->
          Output.die(
            "could not locate the Arbiter project root (no compose.yml found)",
            "Set ARB_HOME to your Arbiter checkout, or run `arb update` from inside it."
          )
      end

    Git.ensure_on_integration_branch(root, @integration_branch)
    Git.ensure_clean_tree(root)
    Restart.guard_worker_session!()
    Restart.guard_active_workers!(force)

    before_sha = Git.head_sha(root)
    Git.pull(root, @integration_branch)
    after_sha = Git.head_sha(root)

    if before_sha == after_sha do
      Formatter.emit_up_to_date(mode, @integration_branch)
    else
      commits = Git.short_log(root, before_sha, after_sha)
      Start.log_text("Pulled #{length(commits)} new commit(s); deploying…")

      # Run migrations as an explicit step
      migration_result = Migrate.run(root)

      migrations_applied =
        case migration_result do
          {:ok, count} -> count
          {:error, err} -> Output.die("Database migration failed", err)
        end

      # Check if CLI changed and rebuild/install if needed
      cli_changed =
        root
        |> Git.files_in_diff(before_sha, after_sha)
        |> Enum.any?(&String.starts_with?(&1, "apps/arbiter_cli"))

      cli_built =
        if cli_changed do
          Git.build_and_install_cli(root)
          true
        else
          false
        end

      # Finally restart Phoenix to load the new code
      case Restart.perform(root, timeout_ms) do
        {:ok, actions, was_running} ->
          Formatter.emit_deployed(
            mode,
            @integration_branch,
            before_sha,
            after_sha,
            commits,
            actions,
            was_running,
            migrations_applied,
            cli_built
          )

        {:timeout, actions, _was_running} ->
          Formatter.emit_deploy_timeout(
            mode,
            @integration_branch,
            before_sha,
            after_sha,
            commits,
            actions,
            timeout_ms,
            migrations_applied,
            cli_built
          )
      end
    end
  end

  # ---- issue-edit mode ---------------------------------------------------

  defp do_edit_issue(argv) do
    {opts, rest, mode} = ArgParser.parse(argv, switches: @edit_switches)

    id =
      case rest do
        [id] -> id
        [] -> Output.die("update requires an issue id")
        _ -> Output.die("update takes exactly one positional argument: the issue id")
      end

    existing =
      if opts[:append_notes] do
        case Client.get("/api/issues/" <> id) do
          {:ok, body} -> body
          {:error, err} -> Output.die(err)
        end
      end

    validate_difficulty!(opts[:difficulty])

    payload =
      %{}
      |> put_if("priority", opts[:priority])
      |> put_if("difficulty", opts[:difficulty])
      |> put_if("notes", opts[:notes])
      |> put_if("acceptance", opts[:acceptance])
      |> put_if("qa_notes", opts[:qa_notes])
      |> put_if("deployment_notes", opts[:deployment_notes])
      |> put_if("pr_body", opts[:pr_body])
      |> put_if("status", opts[:status])
      |> put_if("description", opts[:description])
      |> put_if("title", opts[:title])
      |> put_if("assignee", opts[:assignee])
      |> put_if("repo", opts[:repo])
      |> maybe_append_notes(opts[:append_notes], existing)

    if map_size(payload) == 0 do
      Output.die("update requires at least one field flag (e.g. --priority, --append-notes)")
    end

    case Client.patch("/api/issues/" <> id, payload) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp validate_difficulty!(nil), do: :ok
  defp validate_difficulty!(n) when is_integer(n) and n in 0..4, do: :ok

  defp validate_difficulty!(other) do
    Output.die("invalid --difficulty #{inspect(other)} (must be an integer 0..4 / D0..D4)")
  end

  defp maybe_append_notes(payload, nil, _existing), do: payload

  defp maybe_append_notes(payload, addition, existing) do
    combined =
      case existing["notes"] do
        n when n in [nil, ""] -> addition
        prev -> prev <> "\n\n" <> addition
      end

    Map.put(payload, "notes", combined)
  end
end
