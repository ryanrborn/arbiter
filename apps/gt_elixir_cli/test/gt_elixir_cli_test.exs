defmodule GtElixirCliTest do
  use ExUnit.Case
  doctest GtElixirCli

  test "greets the world" do
    assert GtElixirCli.hello() == :world
  end
end
