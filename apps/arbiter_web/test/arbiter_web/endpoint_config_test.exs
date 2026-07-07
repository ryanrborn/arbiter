defmodule ArbiterWeb.EndpointConfigTest do
  use ExUnit.Case

  describe "config/runtime.exs in dev mode" do
    test "requires SECRET_KEY_BASE environment variable for dev config" do
      # Simulate loading dev config without SECRET_KEY_BASE set
      # The runtime config should raise an error when the env var is missing
      assert_raise RuntimeError, ~r/SECRET_KEY_BASE is missing/, fn ->
        # Clear the env var if it exists
        original_value = System.get_env("SECRET_KEY_BASE")
        System.delete_env("SECRET_KEY_BASE")

        try do
          # Attempt to load the config by re-evaluating the runtime block
          # This simulates what happens when the app starts in dev mode
          Config.Reader.read!("../../config/runtime.exs", env: :dev)
        after
          # Restore original value
          if original_value do
            System.put_env("SECRET_KEY_BASE", original_value)
          end
        end
      end
    end
  end
end
