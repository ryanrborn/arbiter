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

  # Shape-based, not value-based: these catch a credential nobody registered
  # as a workspace secret — a token an agent echoed, or one an operator pasted
  # into a coordinator session's raw PTY stream (`Arbiter.Sessions.Transcript`,
  # §11). Longest/most-specific patterns are not order-sensitive here the way
  # `redact/2`'s value list is, because each pattern matches a disjoint shape.
  @credential_patterns [
    ~r/sk-ant-[A-Za-z0-9_-]{20,}/,
    ~r/sk-[A-Za-z0-9]{20,}/,
    ~r/gh[pousr]_[A-Za-z0-9]{20,}/,
    ~r/AKIA[0-9A-Z]{16}/,
    ~r/xox[baprs]-[A-Za-z0-9-]{10,}/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s,
    ~r/Bearer\s+[A-Za-z0-9\-_.=]{20,}/
  ]

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

  @doc """
  Scrub common credential-shaped substrings by pattern rather than by exact
  value — complementary to `redact/2`, not a replacement for it. `redact/2`
  only ever removes a value a human explicitly marked secret; this catches
  the shape of a live token nobody registered (`Arbiter.Sessions.Transcript`
  runs both, in that order, on every byte of a coordinator session's raw PTY
  capture).
  """
  @spec redact_patterns(String.t()) :: String.t()
  @spec redact_patterns(term()) :: term()
  def redact_patterns(text) when is_binary(text) do
    Enum.reduce(@credential_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, @placeholder)
    end)
  end

  def redact_patterns(text), do: text
end
