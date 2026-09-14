defmodule ArbiterWeb.ConnCaseSandboxTest do
  # Deliberately does *not* `use ArbiterWeb.ConnCase` — this asserts a property
  # of the other test modules, not of a connection.
  use ExUnit.Case, async: true

  describe "sandbox containment invariant (bd-5scl0c)" do
    @test_root Path.expand("..", __DIR__)

    # A LiveView channel can still be holding a checkout on the single shared
    # sandbox connection when it is killed, and killing it mid-query drops that
    # connection. ExUnit contains *when* that happens — `Phoenix.LiveViewTest`
    # starts each channel under the ExUnit test supervisor, and
    # `ExUnit.OnExitHandler.run/2` terminates that supervisor and waits for its
    # `:DOWN` before the first `on_exit` callback runs — so the death always
    # lands inside the owning test's teardown.
    #
    # What makes that *contained* rather than merely usually-fine is that every
    # module which mounts a LiveView runs `async: false`: there is no
    # concurrently running test to lose the connection out from under.
    #
    # That invariant is load-bearing and invisible — adding `async: true` to a
    # LiveView test would silently turn the residual teardown disconnects back
    # into the cross-test cascade this task removed, and the suite would still
    # be green the day it happened. Assert it.
    test "no async: true ConnCase module mounts a LiveView" do
      offenders =
        for path <- Path.wildcard(Path.join(@test_root, "**/*_test.exs")),
            path != __ENV__.file,
            source = File.read!(path),
            source =~ ~r/use\s+ArbiterWeb\.ConnCase,\s*async:\s*true/,
            source =~ ~r/\blive(_isolated)?\(/,
            do: Path.relative_to(path, @test_root)

      assert offenders == [],
             """
             These modules mount a LiveView and run async: true:

             #{Enum.map_join(offenders, "\n", &("  " <> &1))}

             A LiveView channel is killed during the teardown of the test that
             mounted it, while it may still hold the single shared sandbox
             connection. With a concurrently running test, that drops the
             connection out from under it (bd-5scl0c). Either run the module
             async: false, or stop mounting a LiveView in it.
             """
    end
  end
end
