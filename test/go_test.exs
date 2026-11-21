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

  describe "Grep tool" do
    @tag :tmp_dir
    test "finds matching lines and only-matching text", %{tmp_dir: dir} do
      File.write!(
        Path.join(dir, "page.html"),
        "<html>\n<h1 class=\"t\">Hello</h1><h2>Sub</h2>\n</html>"
      )

      {out, false} = Go.execute_tool("Grep", %{"pattern" => "<h[12]", "path" => dir})
      assert out =~ ~r/page\.html:2:<h1/

      {out, false} =
        Go.execute_tool("Grep", %{
          "pattern" => "<h[12][^>]*>[^<]*",
          "path" => Path.join(dir, "page.html"),
          "only_matching" => true,
          "max_results" => 1
        })

      assert out =~ ~s(page.html:2:<h1 class="t">Hello)
      refute out =~ "Sub"
      assert out =~ "stopped at max_results=1"
    end

    @tag :tmp_dir
    test "reports no matches and bad paths", %{tmp_dir: dir} do
      assert {"No matches", false} = Go.execute_tool("Grep", %{"pattern" => "zzz", "path" => dir})

      assert_raise RuntimeError, fn ->
        Go.execute_tool("Grep", %{"pattern" => "x", "path" => "/nope"})
      end
    end
  end

  describe "Mix tool" do
    test "rejects tasks outside the allowlist" do
      for task <- ["run", "deps.clean", "test --eval System.halt", "", "archive.install"] do
        {output, error?} = Go.execute_tool("Mix", %{"task" => task})

        assert error?
        assert output =~ "Mix task not allowed"
      end
    end
  end
end
