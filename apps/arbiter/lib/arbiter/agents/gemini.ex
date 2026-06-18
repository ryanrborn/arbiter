defmodule Arbiter.Agents.Gemini do
  @moduledoc """
  Gemini agent adapter implementing `Arbiter.Agents.Agent`.

  Favors `agy` CLI binary, falling back to `gemini` CLI binary if `agy` is not on PATH.
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Gemini.Config
  alias Arbiter.Agents.SecurityPolicy

  @done_regex ~r/\barb done\b/

  # The gemini-cli's own default model (`DEFAULT_GEMINI_MODEL`) — what the CLI
  # runs when we pass no `--model`. Used only to stamp the usage ledger /
  # dashboards via `resolved_model/1`; dispatch behaviour is unchanged.
  @default_model "gemini-2.5-pro"

  @impl true
  def provider, do: "gemini"

  # Gemini/agy CLIs have no per-tool deny lists or fine-grained permission modes
  # analogous to Claude's --permission-mode + --settings. The policy is honored
  # at the coarse level: :bypass maps to --dangerously-skip-permissions / --skip-trust;
  # :auto and :strict omit those flags so the tool does not bypass its own
  # permission checks. Operator-level deny rules and sandbox scoping are not yet
  # enforceable — hence enforced? returns false so the REST posture surface can
  # show the gap rather than claiming full enforcement.
  @impl true
  def security_enforced?, do: false

  @impl true
  def done_sentinel, do: @done_regex

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    case resolve_executable() do
      {:ok, {type, exec}} ->
        policy = security_policy(opts)
        inner = build_argv(type, exec, prompt, opts, policy)
        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | inner]}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def auth_probe_argv(_opts \\ []) do
    # Cheap token-validity probe for whichever CLI is on PATH. A bad/expired key
    # makes Gemini print "API key not valid" / "RESOURCE_EXHAUSTED" (or 401) and
    # exit non-zero — classified by Arbiter.Polecat.StopReason.
    case resolve_executable() do
      {:ok, {_type, exec}} ->
        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", exec, "-p", "ping"]}

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

  # The gemini / agy CLI emits no stream-json `init` event the polecat can read
  # the model from (unlike Claude), so we resolve it up front for the ledger /
  # dashboards. Mirrors `resolve_model/1` (explicit `:model` → tier → workspace
  # `active_model`) but adds a concrete terminal fallback: when nothing is
  # configured the CLI defaults to `gemini-2.5-pro` (`DEFAULT_GEMINI_MODEL` in
  # the gemini-cli), so recording that is accurate even though we pass no
  # `--model` flag in that case.
  @impl true
  def resolved_model(opts \\ []) do
    # resolve_model/1 already chains explicit → tier → workspace active_model;
    # @default_model is the terminal fallback (the gemini-cli's own default).
    resolve_model(opts) || @default_model
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

  # The resolved `Arbiter.Agents.SecurityPolicy` for this spawn. Falls back to
  # the install-wide default so a bare adapter call is still safe.
  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  # :bypass → pass skip-permissions so the tool doesn't gate on confirmations.
  # :auto/:strict → omit the flag; the tool will not bypass its own permission
  # checks. Operator deny rules are not enforceable on Gemini/agy (no --settings
  # equivalent) — see security_enforced?/0.
  defp build_argv(:agy, exec, prompt, opts, %SecurityPolicy{permissions: %{mode: :bypass}}) do
    [exec, "-p", prompt, "--dangerously-skip-permissions"] ++
      model_flag(opts) ++ thinking_flag(opts)
  end

  defp build_argv(:agy, exec, prompt, opts, _policy) do
    [exec, "-p", prompt] ++ model_flag(opts) ++ thinking_flag(opts)
  end

  defp build_argv(:gemini, exec, prompt, opts, %SecurityPolicy{permissions: %{mode: :bypass}}) do
    [exec, "-p", prompt, "--skip-trust", "-y"] ++ model_flag(opts) ++ thinking_flag(opts)
  end

  defp build_argv(:gemini, exec, prompt, opts, _policy) do
    [exec, "-p", prompt] ++ model_flag(opts) ++ thinking_flag(opts)
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
