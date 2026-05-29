defmodule ArbiterCli.Cmd.Msg do
  @moduledoc """
  `arb msg <recipient> <body>` — send a message up (or across) the chain.

  The complement of `arb message`: where `message` is the Admiral handing a
  *direction* down to a running acolyte, `msg` is an acolyte (or the system,
  or you at a terminal) sending a report up to the Admiral — a completion, a
  failure, an escalation, an FYI.

      arb msg admiral "GitLab adapter complete" --kind completion --directive bd-1qx1nt
      arb msg admiral needs attention
      arb msg bd-xyz heads up, the API shape changed

  `<body>` may be multiple words (no quoting required). The recipient is the
  first argument; `admiral` is the usual one.

  Flags:
    --subject "..."     short label for the message
    --directive bd-x    the directive the message concerns (shown in brackets
                        by `arb inbox`)
    --kind K            one of: #{Enum.join(~w(notification completion failure escalation info), " | ")}
                        (default: info)
    --json              emit the created message as JSON

  The `from` identity defaults to the `ARB_FROM` env var (acolytes set it to
  their own name/bead id), falling back to `"cli"` from a terminal.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  @allowed_kinds ~w(notification completion failure escalation info)
  @default_kind "info"

  def run(argv) do
    mode = Output.mode(argv)
    rest = Output.drop_json(argv)

    {opts, positional, _invalid} =
      OptionParser.parse(rest, strict: [subject: :string, directive: :string, kind: :string])

    case positional do
      [recipient | [_ | _] = words] ->
        send_msg(recipient, Enum.join(words, " "), opts, mode)

      [_recipient] ->
        Output.die("msg requires a body: `arb msg <recipient> <body>`")

      _ ->
        Output.die("msg requires: <recipient> <body>")
    end
  end

  defp send_msg(recipient, body, opts, mode) do
    case validate_kind(opts[:kind]) do
      {:ok, kind} ->
        payload =
          %{
            kind: kind,
            from_ref: from_identity(),
            to_ref: recipient,
            body: body,
            workspace_id: Workspace.id_or_halt()
          }
          |> put_optional(:subject, opts[:subject])
          |> put_optional(:directive_ref, opts[:directive])

        case Client.post("/api/messages", payload) do
          {:ok, message} -> emit(message, recipient, kind, mode)
          {:error, err} -> Output.die(err)
        end

      {:error, msg} ->
        Output.die(msg)
    end
  end

  defp validate_kind(nil), do: {:ok, @default_kind}
  defp validate_kind(k) when k in @allowed_kinds, do: {:ok, k}

  defp validate_kind(k),
    do: {:error, "invalid --kind #{inspect(k)} (allowed: #{Enum.join(@allowed_kinds, ", ")})"}

  defp from_identity, do: System.get_env("ARB_FROM") || "cli"

  defp put_optional(map, _key, val) when val in [nil, ""], do: map
  defp put_optional(map, key, val), do: Map.put(map, key, val)

  defp emit(message, _recipient, _kind, :json), do: IO.puts(Jason.encode!(message))
  defp emit(_message, recipient, kind, :text), do: IO.puts("Sent #{kind} to #{recipient}.")
end
