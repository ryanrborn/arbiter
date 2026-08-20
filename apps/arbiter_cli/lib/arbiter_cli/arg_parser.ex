defmodule ArbiterCli.ArgParser do
  @moduledoc """
  Shared `OptionParser` wrapper for `arb` subcommands.

  Most subcommands repeat the same three steps: parse flags out of argv,
  split off positionals, and decide `:text` vs `:json` mode from a `--json`
  switch. `parse/2` does all three in one call so subcommand modules don't
  hand-roll it.
  """

  @doc """
  Parses `argv` against `opts[:switches]` (or `opts[:strict]` for a strict
  parse that rejects unknown flags), returning `{parsed, rest, mode}`.

  `--json` is added to the switches automatically unless already present,
  so every caller gets `:json` mode detection without declaring it. Pass
  `opts[:aliases]` to forward short flags to `OptionParser`.
  """
  @spec parse([String.t()], keyword()) :: {keyword(), [String.t()], :text | :json}
  def parse(argv, opts) do
    parse_opts =
      case Keyword.fetch(opts, :strict) do
        {:ok, strict} -> [strict: with_json(strict)]
        :error -> [switches: with_json(Keyword.get(opts, :switches, []))]
      end

    parse_opts =
      case Keyword.fetch(opts, :aliases) do
        {:ok, aliases} -> parse_opts ++ [aliases: aliases]
        :error -> parse_opts
      end

    {parsed, rest, _invalid} = OptionParser.parse(argv, parse_opts)
    mode = if parsed[:json], do: :json, else: :text
    {parsed, rest, mode}
  end

  defp with_json(switches) do
    if Keyword.has_key?(switches, :json), do: switches, else: switches ++ [json: :boolean]
  end

  @doc """
  Like `parse/2` with `opts[:strict]`, but dies via `ArbiterCli.Output.die/1`
  (or `Output.die/2` when `opts[:hint]` is given) on the first unknown flag
  instead of silently dropping it. `command_label` names the subcommand in
  the error message, e.g. `"arb server deploy"`. `opts[:hint]` is an optional
  `(flag -> String.t())` producing the detail line passed to `Output.die/2`.
  """
  @spec parse_strict!([String.t()], String.t(), keyword()) ::
          {keyword(), [String.t()], :text | :json}
  def parse_strict!(argv, command_label, opts) do
    strict = Keyword.fetch!(opts, :strict)
    parse_opts = [strict: with_json(strict)]

    parse_opts =
      case Keyword.fetch(opts, :aliases) do
        {:ok, aliases} -> parse_opts ++ [aliases: aliases]
        :error -> parse_opts
      end

    {parsed, rest, invalid} = OptionParser.parse(argv, parse_opts)

    if invalid != [] do
      [{flag, _} | _] = invalid
      message = "unknown option #{flag} for `#{command_label}`"

      case Keyword.get(opts, :hint) do
        nil -> ArbiterCli.Output.die(message)
        hint -> ArbiterCli.Output.die(message, hint.(flag))
      end
    end

    mode = if parsed[:json], do: :json, else: :text
    {parsed, rest, mode}
  end

  @doc """
  Runs `fun.()` unless `--help`/`-h` is present in `argv`, in which case
  `usage_text` is printed instead. Mirrors the `if Output.help?(argv) ...`
  guard every subcommand's `run/1` starts with.
  """
  @spec unless_help([String.t()], String.t(), (-> any())) :: any()
  def unless_help(argv, usage_text, fun) do
    if "--help" in argv or "-h" in argv do
      IO.puts(usage_text)
    else
      fun.()
    end
  end
end
