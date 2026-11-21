defmodule GoTest do
  use ExUnit.Case

  # Go.run/1 calls the live Claude API, so the test only checks that it exists.
  test "exposes the agent entry point" do
    Code.ensure_loaded!(Go)
    assert function_exported?(Go, :run, 1)
  end

  describe "Curl tool" do
    @tag :tmp_dir
    test "runs native curl and reports the body and status", %{tmp_dir: dir} do
      path = Path.join(dir, "page.txt")
      File.write!(path, "weekly limit: 42% left")

      {output, error?} = Go.execute_tool("Curl", %{"args" => ["file://" <> path]})

      refute error?
      assert output =~ "weekly limit: 42% left"
      assert output =~ "(exit 0)"
    end

    test "passes arguments without a shell" do
      {output, error?} = Go.execute_tool("Curl", %{"args" => ["file:///nonexistent; echo pwned"]})

      assert error?
      refute output =~ ~r/^pwned$/m
    end
  end
end
