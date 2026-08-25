defmodule ArbiterCli.Cmd.InstallService.EnvFile do
  @moduledoc """
  Reads and writes `<arbiter_home>/arbiter.env`: secret + `PATH` capture for
  `arb install-service`, and the idempotent key/value merge that lets a
  managed key be rewritten in place without disturbing sibling keys or
  comments already in the file.
  """

  alias ArbiterCli.Output

  # Keys forwarded from the installing shell into `.arbiter.env` so the
  # detached, login-less service can still reach GitHub and the model
  # providers. Only keys actually set (and non-empty) in the current
  # environment are written.
  @captured_secrets ~w(
    GITHUB_TOKEN
    CLAUDE_CODE_OAUTH_TOKEN
    ANTHROPIC_API_KEY
    ANTHROPIC_API_KEY_2
    GEMINI_API_KEY
    GOOGLE_GENAI_API_KEY
    ARBITER_CLOAK_KEY
  )

  @doc """
  Forward any of `@captured_secrets` set in the current environment into
  `<arbiter_home>/arbiter.env`, preserving any keys already present. Returns
  `{:written, path, keys}` listing the keys captured, or `{:none, path}` when
  the environment carries none of them.
  """
  @spec capture_secrets(String.t()) ::
          {:written, String.t(), [String.t()]} | {:none, String.t()}
  def capture_secrets(arbiter_home) do
    path = Path.join(arbiter_home, "arbiter.env")

    captured =
      Enum.flat_map(@captured_secrets, fn key ->
        case System.get_env(key) do
          v when is_binary(v) and v != "" -> [{key, v}]
          _ -> []
        end
      end)

    case captured do
      [] ->
        {:none, path}

      pairs ->
        merged = path |> read_env_entries() |> merge_env_entries(pairs)
        write_env_file(path, render_env_entries(merged))
        {:written, path, Enum.map(pairs, &elem(&1, 0))}
    end
  end

  @doc """
  Capture the installing shell's PATH into `<arbiter_home>/arbiter.env` so
  the login-less systemd service can find agent CLIs (e.g. `claude` in
  ~/.local/bin, mise shims) that live outside the stripped system PATH.
  Uses the same idempotent merge as `capture_secrets/1`.
  Called from `arb install service` and from `arb server deploy` (to refresh
  the PATH on every release deploy, preventing stale or test-corrupted values).
  """
  @spec capture_path(String.t()) :: :written | :skipped
  def capture_path(arbiter_home) do
    case System.get_env("PATH") do
      v when is_binary(v) and v != "" ->
        env_path = Path.join(arbiter_home, "arbiter.env")
        merged = env_path |> read_env_entries() |> merge_env_entries([{"PATH", v}])
        write_env_file(env_path, render_env_entries(merged))
        :written

      _ ->
        :skipped
    end
  end

  # Read `.arbiter.env` into an ordered list of entries: `{:kv, key, value}`
  # for `KEY=value` lines and `{:raw, line}` for everything else (comments,
  # blanks). Keeping the raw lines lets us round-trip the file without
  # clobbering the user's own keys or formatting. Missing file → empty.
  defp read_env_entries(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.map(&classify_env_line/1)
        |> drop_trailing_blanks()

      {:error, _} ->
        []
    end
  end

  defp classify_env_line(line) do
    case Regex.run(~r/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/, line) do
      [_, key, value] -> {:kv, key, value}
      _ -> {:raw, line}
    end
  end

  defp drop_trailing_blanks(entries) do
    entries
    |> Enum.reverse()
    |> Enum.drop_while(&match?({:raw, ""}, &1))
    |> Enum.reverse()
  end

  # Update managed keys in place where they already appear; append the rest.
  # Sibling keys (and comments) ride along untouched.
  defp merge_env_entries(entries, pairs) do
    updates = Map.new(pairs)

    {rewritten, seen} =
      Enum.map_reduce(entries, MapSet.new(), fn
        {:kv, key, value}, seen ->
          case Map.fetch(updates, key) do
            {:ok, new_value} -> {{:kv, key, new_value}, MapSet.put(seen, key)}
            :error -> {{:kv, key, value}, seen}
          end

        other, seen ->
          {other, seen}
      end)

    appended =
      pairs
      |> Enum.reject(fn {k, _v} -> MapSet.member?(seen, k) end)
      |> Enum.map(fn {k, v} -> {:kv, k, v} end)

    rewritten ++ appended
  end

  defp render_env_entries(entries) do
    body =
      Enum.map_join(entries, "\n", fn
        {:kv, key, value} -> "#{key}=#{value}"
        {:raw, line} -> line
      end)

    body <> "\n"
  end

  # `.arbiter.env` holds secrets, so it's written 0600 (owner read/write only)
  # on every write — both at creation and when tightening an existing file.
  defp write_env_file(path, body) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, body)
    File.chmod!(path, 0o600)
  rescue
    e in File.Error ->
      Output.die(
        "could not write secrets to #{path}: #{:file.format_error(e.reason)}",
        "Check the destination is writable: #{Path.dirname(path)}"
      )
  end
end
