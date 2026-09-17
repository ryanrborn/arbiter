defmodule Mix.Tasks.Arbiter.RotateCloakKey do
  @shortdoc "Sweep ash_cloak columns onto Arbiter.Vault's current cipher after a key rotation"
  @moduledoc """
  Drives the `Arbiter.Vault.Rotation` sweep. See `docs/cloak-key-rotation.md`
  for the full operator runbook — this is the command reference.

  ## Usage

      mix arbiter.rotate_cloak_key --verify   # count rows still on the retired cipher
      mix arbiter.rotate_cloak_key --sweep    # re-encrypt every row under the current cipher

  Run `--verify` first (mid-rotation, both `ARBITER_CLOAK_KEY` and
  `ARBITER_CLOAK_KEY_OLD` set) to see what's outstanding, then `--sweep` to do
  the re-encryption. `--sweep` is safe to re-run — rows already on the
  current cipher are left untouched. Run `--verify` again afterward; it must
  report zero retired rows before `ARBITER_CLOAK_KEY_OLD` is removed from the
  environment.

  Prints only counts and table/column names — never plaintext or ciphertext.
  """

  use Mix.Task

  alias Arbiter.Vault.Rotation

  @switches [verify: :boolean, sweep: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.start")

    cond do
      opts[:sweep] == true ->
        Mix.shell().info("Sweeping ash_cloak columns onto the current cipher...\n")
        Rotation.sweep!() |> Enum.each(&print_sweep_report/1)

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

  defp print_sweep_report(%{table: table, column: column} = report) do
    Mix.shell().info(
      "  #{table}.#{column}: scanned #{report.scanned}, rotated #{report.rotated}, " <>
        "already current #{report.already_current}"
    )
  end

  defp print_verify_report(%{table: table, column: column, retired: retired}) do
    Mix.shell().info("  #{table}.#{column}: #{retired} row(s) still on the retired cipher")
  end
end
