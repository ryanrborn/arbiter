defmodule Arbiter.ApplicationTest do
  # Pure: `Arbiter.Application.children/1` builds child specs and starts
  # nothing, so no DB / sandbox is involved.
  use ExUnit.Case, async: true

  alias Arbiter.Application

  # Resolve any child spec form — a module, a `{module, arg}` tuple, or an
  # already-normalized map — down to its supervisor child id, the same way
  # `Supervisor` does when it builds the tree.
  defp child_id(spec), do: Supervisor.child_spec(spec, []).id

  describe "children/1 boot wiring" do
    # Regression guard for bd-6k8519, which shipped the SAME boot-breaking
    # duplicate-`:Task`-id collision TWICE. The gated boot children
    # (Arbiter.Polecats.ReconcileGuard, refinery_boot_task) are gated behind
    # `RefinerySupervisor.auto_start?()`, which is false in `test`. So in the
    # test env the children are never appended to the child list and every test
    # — including any supervision-tree test — passes green. Only a real
    # dev/prod boot crashes with "more than one child specification has the id:
    # Task". It took a manual dev boot to catch the bug both times.
    #
    # Passing `auto_start?: true` forces the gated boot children INTO the
    # resolved child list regardless of env, so a future id collision (e.g. a
    # second bare `{Task, fn}` that defaults to the `:Task` id) is caught here
    # by the green suite instead of by a production outage.
    test "every child id is unique with the gated boot tasks included" do
      children = Application.children(auto_start?: true)
      ids = Enum.map(children, &child_id/1)

      assert ids == Enum.uniq(ids),
             "duplicate child ids in Arbiter.Application supervision tree: " <>
               inspect(ids -- Enum.uniq(ids)) <>
               ". Each child spec needs a distinct :id — bare {Task, fn} specs " <>
               "all collapse to the default :Task id and crash the boot."

      # Belt-and-suspenders: `Enum.uniq_by` on the resolved specs must preserve
      # length, the exact invariant the application supervisor enforces at boot.
      assert length(Enum.uniq_by(children, &child_id/1)) == length(children)
    end

    test "the gated boot tasks are present when auto_start? is true" do
      ids = Application.children(auto_start?: true) |> Enum.map(&child_id/1)

      assert Arbiter.Polecats.ReconcileGuard in ids
      assert :refinery_boot_task in ids
    end

    test "the gated boot tasks are absent when auto_start? is false (the test-env default)" do
      ids = Application.children(auto_start?: false) |> Enum.map(&child_id/1)

      refute Arbiter.Polecats.ReconcileGuard in ids
      refute :refinery_boot_task in ids
    end
  end
end
