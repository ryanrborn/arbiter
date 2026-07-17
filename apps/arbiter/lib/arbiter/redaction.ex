defmodule Arbiter.Redaction do
  @moduledoc """
  Scrubs secret substrings out of worker-facing text.

  Used to keep secret-marked worker env vars (see `Arbiter.Worker.WorkerEnv`)
  from surfacing anywhere a human reads worker output — the live dashboard
  stream, the persisted `worker_runs.output_lines` tail, and the durable
  per-run transcript (`Arbiter.Worker.OutputLog`). All three are fed from the
  single `Arbiter.Worker.ClaudeSession` emit path, so redacting there covers
  every surface.

  This is a plain string replace, not a pattern matcher: a subprocess that
  echoes a secret verbatim (a test printing `$TOKEN`, an `env` dump, an error
  quoting the failed command's environment) has the exact secret value in its
  output, and we replace that value with `#{inspect("[REDACTED]")}`.

  Two deliberate safety properties:

    * empty / non-binary secret values are skipped, so a misconfigured empty
      secret can never blank out the entire line;
    * longer secrets are applied first, so when one secret value is a substring
      of another we never leave a trailing fragment of the longer one exposed.
  """

  @placeholder "[REDACTED]"

  @doc "The literal string substituted in place of a redacted secret."
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @doc """
  Replace every occurrence of each secret value in `text` with the redaction
  placeholder.

  `secret_values` may contain `nil`s and empty strings (both ignored). A
  non-binary `text` is returned unchanged, so callers can pipe values through
  without guarding.
  """
  @spec redact(String.t(), [String.t() | nil]) :: String.t()
  @spec redact(term(), [String.t() | nil]) :: term()
  def redact(text, secret_values) when is_binary(text) and is_list(secret_values) do
    secret_values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    # Longest first: if "SEC" and "SECRETLONG" are both secret, redacting the
    # short one first would leave "RETLONG" in the clear.
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(text, fn secret, acc -> String.replace(acc, secret, @placeholder) end)
  end

  def redact(text, _secret_values), do: text
end
