defmodule Arbiter.Test.GuardRefusalScan do
  @moduledoc """
  AST scanner that finds every **refusal path** in a control-plane source file.

  This is the enforcement half of `Arbiter.Reviews.GuardRegistry` (design #1635
  §5.4, invariant I4: *a guard that is not in the registry does not exist*). The
  registry is a list of declarations; on its own a list cannot stop the next
  guard from being added without one. This module is what makes it stop: it
  reads the source of the six control-plane modules and reports the function
  that each refusal originates in, so `guard_registry_test.exs` can assert that
  every one of them is either a registry row's site or an explicitly declared
  non-guard site.

  ## What counts as a refusal

  Three signals, all purely syntactic (no compilation, no runtime), applied to
  every `def`/`defp` in the file:

    * `:name` — the function's **own name** is in the refusal vocabulary:
      `escalate…`, `fail…`, `give_up…`, with any of the
      `do_`/`maybe_`/`safe_`/`debounce_`/`re_`/`try_`/`attempt_` prefixes. This
      is how this codebase already names its refusal leaves
      (`escalate_commit_gate/2`, `fail_closed/3`, `give_up_fix_round/4`).

    * `:prim` — the function body calls a **refusal primitive**: `Worker.fail/2`
      (fail the run), `Message.send_mail/1` (mail the coordinator — an
      escalation) or any `CoordinatorNotifier.*` (page the coordinator). This
      catches a refusal added *inline*, in a `handle_info/2` clause or anywhere
      else that does not adopt the naming convention.

    * `:tagged` — the function body constructs a **tagged refusal tuple**:
      `{:error, :reason}`, `{:error, {:reason, …}}` with a literal atom tag.
      Tick-driven modules (`MergeQueue`) have no worker to fail and no thread to
      post to: they refuse by *returning*, so naming and primitives alone would
      miss `merge_guarded/2` entirely.

  ## Deliberate limits, and why

  `:tagged` is **not** applied to `Arbiter.Worker`. That module's `{:error,
  tag}` returns are overwhelmingly public-API argument validation
  (`:invalid_transition`, `:missing_task_id`, `:port_open_failed` — 32 sites,
  all of them GenServer call plumbing), while its actual refusals reach the
  fleet through `fail/2`, `fail_now/2` and `escalate_*`, which `:name` and
  `:prim` already cover exhaustively. Including it would add ~30 non-guard
  entries whose only effect is to bury the signal.

  `@exception_capture_tags` (`:exit`, `:exception`, `:raised`, `:bad_return`)
  are excluded from `:tagged` everywhere. Those tags come from the `safe_*/1`
  wrappers that turn an exit or a raise into a tuple; they are error *adapters*,
  not refusals of work, and there are nine of them.

  A site is reported at the granularity of `{module, function, arity}` — not per
  clause and not per line — so it survives ordinary edits and does not need
  re-anchoring the way the design doc's `file:line` citations do.
  """

  @name_re ~r/^(do_|maybe_|safe_|debounce_|re_|try_|attempt_)*(escalate|fail|give_up)(_[a-z0-9_]+)*[?!]?$/

  @exception_capture_tags [:exit, :exception, :raised, :bad_return]

  @type signal :: :name | :prim | :tagged
  @type site :: {atom(), arity()}

  @doc """
  Scan `source` and return the refusal sites it contains.

  `signals` selects which of the three detectors run. Returns a map of
  `{function, arity} => [signal_detail]`, sorted by first definition line.
  """
  @spec scan(String.t(), [signal()]) :: [{site(), [String.t()]}]
  def scan(source, signals) do
    source
    |> Code.string_to_quoted!()
    |> clauses()
    |> Enum.flat_map(fn {name, arity, line, body} ->
      details =
        signal_details(:name, signals, fn -> if refusal_name?(name), do: ["name"], else: [] end) ++
          signal_details(:prim, signals, fn -> primitives(body) end) ++
          signal_details(:tagged, signals, fn -> tagged_refusals(body) end)

      if details == [], do: [], else: [{{name, arity}, line, details}]
    end)
    |> Enum.group_by(fn {site, _line, _details} -> site end)
    |> Enum.map(fn {site, entries} ->
      {site,
       entries |> Enum.flat_map(fn {_, _, details} -> details end) |> Enum.uniq() |> Enum.sort(),
       entries |> Enum.map(fn {_, line, _} -> line end) |> Enum.min()}
    end)
    |> Enum.sort_by(fn {_site, _details, line} -> line end)
    |> Enum.map(fn {site, details, _line} -> {site, details} end)
  end

  @doc """
  Every `{function, arity}` defined in `source`.

  Used to assert that a registry row's declared `:sites` still exist — a row
  pointing at a deleted function is as bad as a guard with no row.
  """
  @spec definitions(String.t()) :: [site()]
  def definitions(source) when is_binary(source) do
    source
    |> Code.string_to_quoted!()
    |> clauses()
    |> Enum.map(fn {name, arity, _line, _body} -> {name, arity} end)
    |> Enum.uniq()
  end

  @doc """
  Local functions called (directly) from the body of `{name, arity}` in `source`,
  plus whether that body reaches `Worker.fail/2` or `fail_now/2`.
  """
  @spec call_graph(String.t()) :: %{site() => %{calls: [atom()], fails_run?: boolean()}}
  def call_graph(source) do
    source
    |> Code.string_to_quoted!()
    |> clauses()
    |> Enum.reduce(%{}, fn {name, arity, _line, body}, acc ->
      entry = %{calls: local_calls(body), fails_run?: fails_run?(body)}

      Map.update(acc, {name, arity}, entry, fn existing ->
        %{
          calls: Enum.uniq(existing.calls ++ entry.calls),
          fails_run?: existing.fails_run? or entry.fails_run?
        }
      end)
    end)
  end

  @doc "True when the function's own name is in the refusal vocabulary."
  @spec refusal_name?(atom()) :: boolean()
  def refusal_name?(name), do: Regex.match?(@name_re, Atom.to_string(name))

  ## Internals

  defp signal_details(signal, signals, fun) do
    if signal in signals, do: fun.(), else: []
  end

  # Every `def`/`defp` clause in `ast`, as `{name, arity, line, body}`.
  defp clauses(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {op, meta, [head, body]} = node, acc when op in [:def, :defp] ->
          case name_arity(head) do
            nil -> {node, acc}
            {name, arity} -> {node, [{name, arity, meta[:line], body} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp name_arity({:when, _, [head | _]}), do: name_arity(head)
  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp name_arity({name, _, nil}) when is_atom(name), do: {name, 0}
  defp name_arity(_), do: nil

  defp primitives(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, acc when is_list(args) ->
          {node, [remote_primitive(List.last(parts), fun) | acc]}

        {:send_mail, _, args} = node, acc when is_list(args) ->
          {node, ["send_mail" | acc]}

        {{:., _, [_mod, :send_mail]}, _, args} = node, acc when is_list(args) ->
          {node, ["send_mail" | acc]}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp remote_primitive(:Worker, :fail), do: "Worker.fail"
  defp remote_primitive(:CoordinatorNotifier, fun), do: "CoordinatorNotifier.#{fun}"
  defp remote_primitive(_mod, :send_mail), do: "send_mail"
  defp remote_primitive(_mod, _fun), do: nil

  defp tagged_refusals(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:error, tag} = node, acc when is_atom(tag) ->
          {node, [refusal_tag(tag) | acc]}

        {:error, {tag, _}} = node, acc when is_atom(tag) ->
          {node, [refusal_tag(tag) | acc]}

        {:error, {:{}, _, [tag | _]}} = node, acc when is_atom(tag) ->
          {node, [refusal_tag(tag) | acc]}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp refusal_tag(tag) when tag in @exception_capture_tags, do: nil
  defp refusal_tag(nil), do: nil
  defp refusal_tag(tag), do: "error:#{tag}"

  defp local_calls(body) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(acc)
  end

  defp fails_run?(body) do
    {_, acc} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, parts}, :fail]}, _, args} = node, acc when is_list(args) ->
          {node, acc or List.last(parts) == :Worker}

        {:fail_now, _, args} = node, _acc when is_list(args) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    acc
  end
end
