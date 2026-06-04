defmodule Arbiter.Agents.Gemini do
  @moduledoc """
  Gemini agent adapter implementing `Arbiter.Agents.Agent`.

  Favors `agy` CLI binary, falling back to `gemini` CLI binary if `agy` is not on PATH.
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Gemini.Config

  @done_regex ~r/\barb done\b/

  @impl true
  def provider, do: "gemini"

  @impl true
  def done_sentinel, do: @done_regex

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    case resolve_executable() do
      {:ok, {type, exec}} ->
        inner = build_argv(type, exec, prompt, opts)
        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | inner]}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    api_key_env(opts) ++ thinking_env(opts)
  end

  defp api_key_env(opts) do
    case Keyword.get(opts, :api_key) || Config.resolve_api_key() do
      key when is_binary(key) and key != "" ->
        [
          {"GEMINI_API_KEY", key},
          {"GOOGLE_GENAI_API_KEY", key}
        ]

      _ ->
        []
    end
  end

  defp thinking_env(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> Config.thinking_env(level)
      _ -> []
    end
  end

  @impl true
  def init_session(_opts \\ []) do
    %{
      line_buf: "",
      output_lines: [],
      usage: %{},
      activity: nil,
      activity_at: nil
    }
  end

  @impl true
  def parse_line(session, line) when is_binary(line) do
    # Gemini and agy print output line-by-line. Since they may output plain text
    # or json, we support basic text streaming fallback: treat each line as a
    # raw output line.
    next = Map.update!(session, :output_lines, &[line | &1])
    {[{line, !tool_result_line?(line)}], next}
  end

  @impl true
  def usage_attrs(session) do
    Map.get(session, :usage, %{})
    |> Map.put(:provider, provider())
  end

  # ---- Internals ---------------------------------------------------------

  defp tool_result_line?(line) when is_binary(line),
    do: String.starts_with?(line, "⏴ ")

  defp tool_result_line?(_), do: false

  defp resolve_executable do
    case System.find_executable("agy") do
      path when is_binary(path) ->
        {:ok, {:agy, path}}

      nil ->
        case System.find_executable("gemini") do
          path when is_binary(path) ->
            {:ok, {:gemini, path}}

          nil ->
            {:error, {:executable_not_found, "agy or gemini"}}
        end
    end
  end

  defp build_argv(:agy, exec, prompt, opts) do
    [exec, "-p", prompt, "--dangerously-skip-permissions"] ++
      model_flag(opts) ++ thinking_flag(opts)
  end

  defp build_argv(:gemini, exec, prompt, opts) do
    [exec, "-p", prompt, "--skip-trust", "-y"] ++ model_flag(opts) ++ thinking_flag(opts)
  end

  defp model_flag(opts) do
    case resolve_model(opts) do
      nil -> []
      model when is_binary(model) -> ["--model", model]
    end
  end

  defp resolve_model(opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        case Keyword.get(opts, :model_tier) do
          tier when is_binary(tier) and tier != "" ->
            Config.model_for_tier(tier) || Config.active_model()

          _ ->
            Config.active_model()
        end
    end
  end

  defp thinking_flag(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> Config.thinking_argv(level)
      _ -> []
    end
  end
end
