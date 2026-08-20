defmodule ArbiterCli.Cmd.Update.Git do
  @moduledoc """
  Git + CLI-rebuild side of `arb update`'s deploy mode: branch/tree checks,
  `git pull --ff-only`, commit/diff inspection, and rebuilding the CLI
  escript when it changed.
  """

  alias ArbiterCli.Cmd.Start
  alias ArbiterCli.Output

  @spec ensure_on_integration_branch(String.t(), String.t()) :: :ok | no_return()
  def ensure_on_integration_branch(root, integration_branch) do
    case git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {out, 0} ->
        branch = String.trim(out)

        unless branch == integration_branch do
          Output.die(
            "the checkout is on `#{branch}`, not the integration branch `#{integration_branch}`",
            "`arb update` fast-forwards `#{integration_branch}`. " <>
              "Switch with `git checkout #{integration_branch}` first."
          )
        end

        :ok

      {out, _code} ->
        Output.die(
          "could not determine the current git branch",
          "Is #{root} a git checkout? Output:\n" <> String.trim_trailing(out)
        )
    end
  end

  @spec ensure_clean_tree(String.t()) :: :ok | no_return()
  def ensure_clean_tree(root) do
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

  @spec head_sha(String.t()) :: String.t()
  def head_sha(root) do
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

  @spec pull(String.t(), String.t()) :: :ok | no_return()
  def pull(root, integration_branch) do
    Start.log_text("Pulling #{integration_branch} (git pull --ff-only)…")

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
  @spec short_log(String.t(), String.t(), String.t()) :: [%{sha: String.t(), subject: String.t()}]
  def short_log(root, before_sha, after_sha) do
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

  @spec files_in_diff(String.t(), String.t(), String.t()) :: [String.t()]
  def files_in_diff(root, before_sha, after_sha) do
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
  @spec build_and_install_cli(String.t()) :: :ok
  def build_and_install_cli(root) do
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
            :ok

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
end
