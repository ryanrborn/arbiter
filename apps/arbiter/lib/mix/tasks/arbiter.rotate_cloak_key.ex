defmodule Mix.Tasks.Arbiter.RotateCloakKey do
  @shortdoc "Sweep ash_cloak columns onto Arbiter.Vault's current cipher after a key rotation"
  @moduledoc """
  Drives the `Arbiter.Vault.Rotation` sweep. See `docs/cloak-key-rotation.md`
  for the full operator runbook — this is the command reference.

  ## Usage

      mix arbiter.rotate_cloak_key --verify   # count rows still on the retired cipher
      mix arbiter.rotate_cloak_key --sweep    # re-encrypt every row under the current cipher

  Run `--verify` first, mid-rotation (`ARBITER_CLOAK_KEY`,
  `ARBITER_CLOAK_KEY_OLD`, and a bumped `ARBITER_CLOAK_KEY_GENERATION` all
  set together — see `Arbiter.Vault`'s moduledoc), to see what's
  outstanding, then `--sweep` to do the re-encryption. `--sweep` is safe to
  re-run — rows already on the current cipher are left untouched. Run
  `--verify` again afterward; it must report zero retired rows before
  `ARBITER_CLOAK_KEY_OLD` is removed from the environment (keep
  `ARBITER_CLOAK_KEY_GENERATION` at its bumped value permanently).

  Prints only counts and table/column names — never plaintext or ciphertext.

  ## It starts the Repo and the Vault, not the application

  Deliberately no `Mix.Task.run("app.start")`: booting the full application
  next to a live coordinator would start a second endpoint on the same port,
  a second Autopilot and a second set of patrols against the same database
  (see `mix arbiter.backfill_issue_repos` for the same precedent). This task
  starts only the Ecto repo and the `Arbiter.Vault` GenServer it needs to
  decrypt/re-encrypt rows — both are no-ops if already running (e.g. an
  attached node or an iex session that started the app).
  """

  use Mix.Task

  alias Arbiter.Vault.Rotation

  @switches [verify: :boolean, sweep: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    start_deps!()

    cond do
      opts[:sweep] == true ->
        Mix.shell().info("Sweeping ash_cloak columns onto the current cipher...\n")
        reports = Rotation.sweep!()
        Enum.each(reports, &print_sweep_report/1)

        if Enum.any?(reports, &(&1.skipped_changed > 0)) do
          Mix.shell().info(
            "\nSome rows changed concurrently and were skipped — re-run `--sweep` to pick them up."
          )
        end

      opts[:verify] == true ->
        Mix.shell().info("Checking for rows still on the retired cipher...\n")
        reports = Rotation.verify()
        Enum.each(reports, &print_verify_report/1)

        if Enum.any?(reports, &(&1.retired > 0)) do
          Mix.raise(
            "Rotation incomplete: retired-cipher rows remain. Run `mix arbiter.rotate_cloak_key --sweep`."
          )
        else
          Mix.shell().info("\nAll clear — safe to drop ARBITER_CLOAK_KEY_OLD and redeploy.")
        end

      true ->
        Mix.raise("Pass --verify or --sweep. See `mix help arbiter.rotate_cloak_key`.")
    end
  end

  defp start_deps! do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ash)
    {:ok, _} = Application.ensure_all_started(:ash_sqlite)

    case Arbiter.Repo.start_link(pool_size: 1) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Arbiter.Vault.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp print_sweep_report(%{table: table, column: column} = report) do
    Mix.shell().info(
      "  #{table}.#{column}: scanned #{report.scanned}, rotated #{report.rotated}, " <>
        "already current #{report.already_current}, skipped (changed concurrently) " <>
        "#{report.skipped_changed}"
    )
  end

  defp print_verify_report(%{table: table, column: column, retired: retired}) do
    Mix.shell().info("  #{table}.#{column}: #{retired} row(s) still on the retired cipher")
  end
end
