defmodule ArbiterWeb.SessionStreamNodeTest do
  @moduledoc """
  Runs the browser terminal's JavaScript unit tests as part of `mix test`
  (bd-c76fu9, phase 5 acceptance criteria 2 and 3).

  `assets/js/session_stream.mjs` owns the resume protocol the terminal hook
  depends on — the `last_seq` rejoin closure, duplicate suppression after a
  reconnect, binary stdin framing, the debounced resize. A JS test suite that
  only runs when somebody remembers to type `node --test` is a suite that
  stops running, so this shells out to it and fails the Elixir build with its
  transcript attached.

  No npm: `node:test` and `node:assert` are built in (RFC §6.1), which is the
  same bargain `ArbiterWeb.SessionTransportSocketTest` already makes.
  """
  use ExUnit.Case, async: true

  @moduletag :node

  @root Path.expand("../../../../..", __DIR__)
  @suite "apps/arbiter_web/test/js/session_stream_test.mjs"

  test "node --test apps/arbiter_web/test/js passes" do
    node = System.find_executable("node") || flunk("node is required by the :node tag")

    {output, status} =
      System.cmd(node, ["--test", @suite], cd: @root, stderr_to_stdout: true)

    assert status == 0, "the browser terminal's JS suite failed:\n\n#{output}"
    assert output =~ ~r/# fail 0|fail 0/
  end
end
