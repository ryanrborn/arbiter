defmodule ArbiterCli.Cmd.Breaker do
  @moduledoc """
  Shared circuit-breaker subcommands (bd-5jr49o):

      arb breaker list [--workspace W] [--kind K] [--open]
                                        — show live breaker state plus the
                                          registry of every gated call site
      arb breaker reset <signature>     — close one tripped breaker
      arb breaker reset --all [--workspace W] [--kind K]
                                        — close every breaker in a scope

  A breaker trips when the same signature — workspace + kind + normalised
  subject — fires more than K times inside its window. While open, the action
  behind it (filing a ticket, sending an escalation, re-dispatching a task) is
  suppressed, and the coordinator was paged exactly once naming the signature.

  `list` always prints the call-site registry, even on a freshly-restarted
  server where nothing has tripped yet, so "what is gated?" has an answer
  independent of runtime state.

  Fix the underlying condition BEFORE resetting: a breaker whose cause is still
  live simply trips again, and in the meantime the flood resumes.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      rest = Output.drop_json(argv)
      mode = Output.mode(argv)

      case rest do
        ["list" | args] -> list(args, mode)
        ["reset" | args] -> reset(args, mode)
        _ -> unknown()
      end
    end
  end

  defp unknown do
    IO.puts(:stderr, "arb: unknown breaker subcommand")
    IO.puts(:stderr, "Run `arb breaker --help` for usage.")
    Output.halt(2)
  end

  defp list(args, mode) do
    params =
      []
      |> put_flag(args, "--workspace", :workspace)
      |> put_flag(args, "--kind", :kind)
      |> then(fn p -> if "--open" in args, do: [{:open_only, "true"} | p], else: p end)

    case Client.get("/api/breakers", params) do
      {:ok, body} ->
        if mode == :json, do: IO.puts(Jason.encode!(body)), else: print_list(body)

      error ->
        die(error)
    end
  end

  defp reset(args, mode) do
    body =
      cond do
        "--all" in args ->
          %{all: true}
          |> put_opt(args, "--workspace", :workspace)
          |> put_opt(args, "--kind", :kind)

        signature = Enum.find(args, &(not String.starts_with?(&1, "--"))) ->
          %{signature: signature}

        true ->
          Output.die(
            "arb breaker reset needs a signature, or --all",
            "Run `arb breaker list` to see the signatures currently tripped."
          )
      end

    case Client.post("/api/breakers/reset", body) do
      {:ok, resp} ->
        if mode == :json do
          IO.puts(Jason.encode!(resp))
        else
          IO.puts("Closed #{resp["reset"]} circuit breaker(s).")
        end

      error ->
        die(error)
    end
  end

  defp print_list(body) do
    breakers = body["breakers"] || []

    if breakers == [] do
      IO.puts("No circuit breakers have fired since the last restart.")
    else
      IO.puts("BREAKERS (#{body["open_count"]} open of #{length(breakers)})")

      Enum.each(breakers, fn b ->
        state = if b["open"], do: "OPEN", else: "closed"

        IO.puts(
          "  [#{state}] #{b["kind"]}  #{b["count"]}/#{b["limit"]} in " <>
            "#{div(b["window_ms"], 60_000)}m, #{b["suppressed"]} suppressed"
        )

        IO.puts("      #{b["signature"]}")
      end)
    end

    IO.puts("")
    IO.puts("REGISTERED CALL SITES")

    Enum.each(body["call_sites"] || [], fn s ->
      IO.puts(
        "  #{s["kind"]}  (K=#{s["limit"]} / #{div(s["window_ms"], 60_000)}m)  #{s["module"]}"
      )
    end)
  end

  # `--flag value` → a query param, when present.
  defp put_flag(params, args, flag, key) do
    case flag_value(args, flag) do
      nil -> params
      value -> [{key, value} | params]
    end
  end

  defp put_opt(body, args, flag, key) do
    case flag_value(args, flag) do
      nil -> body
      value -> Map.put(body, key, value)
    end
  end

  defp flag_value(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      idx -> Enum.at(args, idx + 1)
    end
  end

  defp die({:error, %Client.Error{kind: :http, body: body}}) when is_map(body) do
    Output.die(get_in(body, ["error", "message"]) || inspect(body))
  end

  defp die({:error, %Client.Error{message: msg}}), do: Output.die(msg)
end
