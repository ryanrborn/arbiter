defmodule ArbiterCli.Cmd.Update do
  @moduledoc """
  `arb update` wears two hats, chosen by whether you name an issue.

  ## Deploy mode — `arb update [--timeout SECONDS] [--json]`

  With **no issue id**, `arb update` deploys freshly-merged work: it
  `git pull --ff-only`s the integration branch (`main`) in the Arbiter
  checkout, then runs an explicit deploy sequence: migrations → CLI escript
  rebuild (if changed) → Phoenix restart. One verb for the contributor +
  Admiral to ship merged work.

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
                      [--description d] [--assignee a]
                      [--qa-notes text] [--deployment-notes text]
                      [--pr-body text]

  `--qa-notes` / `--deployment-notes` set the gated completion-notes fields
  an acolyte produces for tracker-backed work (QA Testing Notes / Deployment
  Notes on the Jira ticket). They overwrite the field (unlike `--append-notes`).

  `--pr-body` sets the acolyte-authored PR/MR description the Refinery opens
  the bead's single canonical PR with (Summary / Test plan / References). It
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

  alias ArbiterCli.{Client, Cmd.Doctor, Cmd.Migrate, Cmd.Restart, Cmd.Start, Output}

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
    qa_notes: :string,
    deployment_notes: :string,
    pr_body: :string,
    status: :string,
    description: :string,
    title: :string,
    assignee: :string,
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
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @deploy_switches)

    if invalid != [] do
      [{flag, _} | _] = invalid

      Output.die(
        "unknown option #{flag} for `arb update`",
        "To deploy, run `arb update` with no issue id. To edit an issue, " <>
          "name it: `arb update <id> #{flag} …`."
      )
    end

    mode = if opts[:json], do: :json, else: :text
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

    ensure_on_integration_branch(root)
    ensure_clean_tree(root)
    Restart.guard_acolyte_session!()
    Restart.guard_active_polecats!(force)

    before_sha = head_sha(root)
    git_pull(root)
    after_sha = head_sha(root)

    if before_sha == after_sha do
      emit_up_to_date(mode)
    else
      commits = short_log(root, before_sha, after_sha)
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
        files_in_diff(root, before_sha, after_sha)
        |> Enum.any?(&String.starts_with?(&1, "apps/arbiter_cli"))

      cli_built =
        if cli_changed do
          build_and_install_cli(root)
          true
        else
          false
        end

      # Finally restart Phoenix to load the new code
      case Restart.perform(root, timeout_ms) do
        {:ok, actions, was_running} ->
          emit_deployed(
            mode,
            before_sha,
            after_sha,
            commits,
            actions,
            was_running,
            migrations_applied,
            cli_built
          )

        {:timeout, actions, _was_running} ->
          emit_deploy_timeout(
            mode,
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

  # ---- git ---------------------------------------------------------------

  defp ensure_on_integration_branch(root) do
    case git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {out, 0} ->
        branch = String.trim(out)

        unless branch == @integration_branch do
          Output.die(
            "the checkout is on `#{branch}`, not the integration branch `#{@integration_branch}`",
            "`arb update` fast-forwards `#{@integration_branch}`. " <>
              "Switch with `git checkout #{@integration_branch}` first."
          )
        end

      {out, _code} ->
        Output.die(
          "could not determine the current git branch",
          "Is #{root} a git checkout? Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  defp ensure_clean_tree(root) do
    case git(root, ["status", "--porcelain"]) do
      {"", 0} ->
        :ok

      {out, 0} ->
        # `??` lines are untracked files — safe to ignore for a fast-forward
        # deploy. Only tracked modifications (staged or unstaged) block the update.
        tracked =
          out
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.starts_with?(&1, "??"))

        if tracked == [] do
          :ok
        else
          Output.die(
            "the working tree has uncommitted changes",
            "Commit or stash them before `arb update`:\n" <> Enum.join(tracked, "\n")
          )
        end

      {out, _code} ->
        Output.die(
          "could not read git status",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  defp head_sha(root) do
    case git(root, ["rev-parse", "HEAD"]) do
      {out, 0} ->
        String.trim(out)

      {out, _code} ->
        Output.die(
          "could not read HEAD",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  defp git_pull(root) do
    Start.log_text("Pulling #{@integration_branch} (git pull --ff-only)…")

    case git(root, ["pull", "--ff-only"]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Output.die(
          "git pull --ff-only failed (exit #{code})",
          "The branch may have diverged from its upstream (a non-fast-forward). " <>
            "Resolve it manually. Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  # `git log --oneline old..new` → a list of {sha, subject} for the new commits.
  defp short_log(root, before_sha, after_sha) do
    case git(root, ["log", "--oneline", "--no-decorate", "#{before_sha}..#{after_sha}"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, " ", parts: 2) do
            [sha, subject] -> %{sha: sha, subject: subject}
            [sha] -> %{sha: sha, subject: ""}
          end
        end)

      {_out, _code} ->
        # The pull already succeeded; a log failure shouldn't abort the deploy.
        []
    end
  end

  # Get the list of files that changed between two commits
  defp files_in_diff(root, before_sha, after_sha) do
    case git(root, ["diff", "--name-only", "#{before_sha}..#{after_sha}"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)

      {_out, _code} ->
        # The pull already succeeded; a diff failure shouldn't abort the deploy.
        []
    end
  end

  # Build the CLI escript and install it to ~/.local/bin/arb
  defp build_and_install_cli(root) do
    cli_dir = Path.join(root, "apps/arbiter_cli")

    Start.log_text("Building CLI escript (mix escript.build)…")

    case Start.run_cmd("mix", ["escript.build"], cd: cli_dir, stderr_to_stdout: true) do
      {_out, 0} ->
        escript_path = Path.join(cli_dir, "arb")
        install_path = Path.join(System.user_home!(), ".local/bin/arb")

        # Ensure ~/.local/bin exists
        install_dir = Path.dirname(install_path)
        File.mkdir_p!(install_dir)

        # Copy the escript to ~/.local/bin/arb
        case File.copy(escript_path, install_path) do
          {:ok, _} ->
            # Make it executable
            File.chmod!(install_path, 0o755)
            Start.log_text("Installed CLI escript to #{install_path}")

          {:error, reason} ->
            Output.die(
              "failed to install CLI escript",
              "Could not copy escript to #{install_path}: #{inspect(reason)}"
            )
        end

      {out, code} ->
        Output.die(
          "failed to build CLI escript (exit #{code})",
          "Output:\n" <> String.trim_trailing(out)
        )
    end
  rescue
    e in ErlangError ->
      Output.die(
        "could not run mix: #{inspect(e.original)}",
        "Ensure Elixir/`mix` is installed and on your PATH."
      )
  end

  # `git`, routed through `arb start`'s `:bd2_cmd_runner` seam so one test stub
  # covers the pull and the reused restart. Always run inside `root`.
  defp git(root, args) do
    Start.run_cmd("git", args, cd: root, stderr_to_stdout: true)
  rescue
    e in ErlangError ->
      Output.die(
        "could not run git: #{inspect(e.original)}",
        "Ensure git is installed and on your PATH."
      )
  end

  # ---- deploy output -----------------------------------------------------

  defp emit_up_to_date(:json) do
    IO.puts(
      Jason.encode!(%{
        branch: @integration_branch,
        pulled: false,
        up_to_date: true,
        restarted: false,
        commits: [],
        ok: true
      })
    )
  end

  defp emit_up_to_date(:text) do
    IO.puts("Already up to date on #{@integration_branch} — nothing to deploy.")
    IO.puts("(Run `arb restart` if you want to bounce Phoenix anyway.)")
  end

  defp emit_deployed(
         :json,
         before_sha,
         after_sha,
         commits,
         actions,
         was_running,
         migrations_applied,
         cli_built
       ) do
    IO.puts(
      Jason.encode!(%{
        branch: @integration_branch,
        pulled: true,
        up_to_date: false,
        restarted: true,
        was_running: was_running,
        old_sha: before_sha,
        new_sha: after_sha,
        commits: commits,
        actions: action_payload(actions),
        migrations_applied: migrations_applied,
        cli_rebuilt: cli_built,
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: Doctor.green?()
      })
    )
  end

  defp emit_deployed(
         :text,
         _before,
         _after,
         commits,
         _actions,
         _was_running,
         migrations_applied,
         cli_built
       ) do
    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s) onto #{@integration_branch}:")
    print_commits(commits)
    IO.puts("")

    if migrations_applied > 0 do
      IO.puts("Applied #{migrations_applied} migration(s)")
    else
      IO.puts("Database schema already current (no migrations to apply)")
    end

    if cli_built do
      IO.puts("Rebuilt and installed CLI escript")
    end

    IO.puts("")
    IO.puts("Arbiter Phoenix restarted at #{Client.base_url()}")
    IO.puts("")
    Doctor.report()
  end

  defp emit_deploy_timeout(
         :json,
         before_sha,
         after_sha,
         commits,
         actions,
         timeout_ms,
         migrations_applied,
         cli_built
       ) do
    IO.puts(
      Jason.encode!(%{
        branch: @integration_branch,
        pulled: true,
        up_to_date: false,
        restarted: false,
        old_sha: before_sha,
        new_sha: after_sha,
        commits: commits,
        actions: action_payload(actions),
        migrations_applied: migrations_applied,
        cli_rebuilt: cli_built,
        base_url: Client.base_url(),
        checks: Enum.map(Doctor.checks(), &Map.from_struct/1),
        ok: false,
        timed_out_after_s: div(timeout_ms, 1000)
      })
    )

    Output.halt(1)
  end

  defp emit_deploy_timeout(
         :text,
         _before,
         _after,
         commits,
         _actions,
         timeout_ms,
         migrations_applied,
         cli_built
       ) do
    IO.puts("")
    IO.puts("Pulled #{length(commits)} new commit(s) onto #{@integration_branch}:")
    print_commits(commits)
    IO.puts("")

    if migrations_applied > 0 do
      IO.puts("Applied #{migrations_applied} migration(s)")
    else
      IO.puts("Database schema already current (no migrations to apply)")
    end

    if cli_built do
      IO.puts("Rebuilt and installed CLI escript")
    end

    IO.puts("")
    IO.puts("…but Phoenix did not come back up within #{div(timeout_ms, 1000)}s.")
    IO.puts("Last status:")
    IO.puts("")
    Doctor.report()
    IO.puts("")
    IO.puts("hint: tail #{Start.phoenix_log_path()} for Phoenix startup output.")
    Output.halt(1)
  end

  defp print_commits(commits) do
    Enum.each(commits, fn %{sha: sha, subject: subject} ->
      IO.puts("  #{sha}  #{subject}")
    end)
  end

  defp action_payload(actions) do
    Enum.map(actions, fn {component, status, detail} ->
      base = %{component: to_string(component), status: to_string(status)}
      if is_list(detail), do: Map.put(base, :pids, detail), else: base
    end)
  end

  # ---- issue-edit mode ---------------------------------------------------

  defp do_edit_issue(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @edit_switches)
    mode = if opts[:json], do: :json, else: :text

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
      |> put_if("qa_notes", opts[:qa_notes])
      |> put_if("deployment_notes", opts[:deployment_notes])
      |> put_if("pr_body", opts[:pr_body])
      |> put_if("status", opts[:status])
      |> put_if("description", opts[:description])
      |> put_if("title", opts[:title])
      |> put_if("assignee", opts[:assignee])
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
