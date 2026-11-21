defmodule GoTest do
  use ExUnit.Case

  # Go.run/1 calls the live Claude API, so the test only checks that it exists.
  test "exposes the agent entry point" do
    Code.ensure_loaded!(Go)
    assert function_exported?(Go, :run, 1)
  end
end
