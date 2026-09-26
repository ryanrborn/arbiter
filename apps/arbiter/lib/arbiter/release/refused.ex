defmodule Arbiter.Release.Refused do
  @moduledoc """
  A refusal from an `Arbiter.Release` operation — a missing option, a plan
  that fails validation, a file that would be overwritten.

  Under `bin/arbiter eval` it surfaces as the printed exception and a non-zero
  exit status, which is what an operator script should see. The Mix wrappers
  over the same functions rescue it and re-raise it as a `Mix.Error`, so the
  Mix path keeps its usual clean one-line failure.

  The message never carries a credential value: every message is built from
  option names, paths, key names and fingerprints only.
  """

  defexception [:message]
end
