# Unit tests for harness.exs. Run with: elixir harness_test.exs
# None of these call the Claude API.

Application.put_env(:go, :no_main, true)
Code.require_file("harness.exs", __DIR__)

ExUnit.start()

defmodule GoTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

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

  describe "instruction context" do
    test "system prompt lists exactly the tools the API receives" do
      prompt = Go.system_prompt("/some/project")

      assert prompt =~ "Working directory: /some/project"
      names = Enum.map_join(Go.tools(), ", ", & &1.name)
      assert prompt =~ "Your only tools are #{names};"
    end

    @tag :tmp_dir
    test "first message is just the prompt when there is no AGENTS.md", %{tmp_dir: dir} do
      assert Go.first_message("hello", dir) == "hello"
    end

    @tag :tmp_dir
    test "first message puts AGENTS.md in front of the prompt", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "# Rules\nUse tabs.\n\n")

      message = Go.first_message("fix the bug", dir)

      assert message =~ ~s(<project_instructions source="AGENTS.md">)
      assert message =~ "# Rules\nUse tabs.\n</project_instructions>"
      assert String.ends_with?(message, "</project_instructions>\n\nfix the bug")
    end
  end

  describe "prompt caching" do
    test "caches the tools + system prefix and the growing conversation" do
      body = Go.request_body([%{role: "user", content: "hi"}], "/some/project")

      assert body.cache_control == %{type: "ephemeral"}
      assert [%{type: "text", text: text, cache_control: %{type: "ephemeral"}}] = body.system
      assert text == Go.system_prompt("/some/project")
    end

    test "the cached prefix is byte-identical across requests" do
      first = Go.request_body([%{role: "user", content: "a"}], "/p")
      later = Go.request_body([%{role: "user", content: "b"}], "/p")

      assert Map.take(first, [:model, :system, :tools]) ==
               Map.take(later, [:model, :system, :tools])
    end
  end

  describe "bug fixes" do
    @tag :tmp_dir
    test "Edit rejects an empty old_string with a clear message", %{tmp_dir: dir} do
      path = Path.join(dir, "f.txt")
      File.write!(path, "abc")

      assert_raise RuntimeError, "old_string must not be empty", fn ->
        Go.execute_tool("Edit", %{"file_path" => path, "old_string" => "", "new_string" => "x"})
      end

      assert File.read!(path) == "abc"
    end

    @tag :tmp_dir
    test "Read truncates large files and says so", %{tmp_dir: dir} do
      path = Path.join(dir, "big.txt")
      File.write!(path, String.duplicate("a", 60_000))

      {output, false} = Go.execute_tool("Read", %{"file_path" => path})

      assert output =~ "(truncated: showing the first 50000 of 60000 characters"
      assert String.length(output) < 50_200
    end

    @tag :tmp_dir
    test "Grep skips _build, deps and node_modules unless asked", %{tmp_dir: dir} do
      for sub <- ["lib", "deps/req", "_build/dev", "node_modules/x"] do
        File.mkdir_p!(Path.join(dir, sub))
        File.write!(Path.join([dir, sub, "f.ex"]), "needle")
      end

      {out, false} = Go.execute_tool("Grep", %{"pattern" => "needle", "path" => dir})
      assert out =~ "lib/f.ex"
      refute out =~ ~r{/(deps|_build|node_modules)/}

      {out, false} =
        Go.execute_tool("Grep", %{"pattern" => "needle", "path" => Path.join(dir, "deps")})

      assert out =~ "deps/req/f.ex"
    end

    test "a blank prompt asks at > and blank lines are skipped" do
      output =
        capture_io("\n  \nexit\n", fn ->
          send(self(), {:result, Go.run("   ")})
        end)

      assert_received {:result, :ok}
      assert output =~ ">"
    end

    test "read_user_input returns text, or :exit on exit or Ctrl-D" do
      capture_io("\nhello\n", fn -> send(self(), Go.read_user_input()) end)
      assert_received {:message, "hello"}

      capture_io("quit\n", fn -> send(self(), Go.read_user_input()) end)
      assert_received :exit

      capture_io("", fn -> send(self(), Go.read_user_input()) end)
      assert_received :exit
    end
  end

  describe "loop visibility" do
    test "turn status adds up the prompt size from the usage fields" do
      usage = %{
        "input_tokens" => 4,
        "cache_read_input_tokens" => 2206,
        "cache_creation_input_tokens" => 18,
        "output_tokens" => 57
      }

      assert Go.turn_status(2, "tool_use", usage) ==
               "[turn 2] stop_reason=tool_use | prompt 2228 tokens " <>
                 "(cache read 2206, cache write 18, uncached 4) | output 57 tokens"
    end

    test "result summary shows status, size and the start of the first line" do
      assert Go.result_summary("line one\nline two", false) == "ok, 17 chars: line one"
      assert Go.result_summary("boom", true) == "error, 4 chars: boom"
    end
  end

  describe "input and slash commands" do
    test "parse_input tells messages, commands, blanks and exit apart" do
      assert Go.parse_input("  \n") == :blank
      assert Go.parse_input("quit\n") == :exit
      assert Go.parse_input("fix the bug\n") == {:message, "fix the bug"}
      assert Go.parse_input("/compact\n") == {:command, "compact", ""}

      assert Go.parse_input("/compact keep the API decisions") ==
               {:command, "compact", "keep the API decisions"}

      assert Go.parse_input("/home/me/app is broken") == {:message, "/home/me/app is broken"}
    end

    test "a command before the first message asks again instead of sending it" do
      output =
        capture_io("/compact\nexit\n", fn -> send(self(), {:result, Go.run("")}) end)

      assert output =~ "/compact needs a conversation first"
      assert_received {:result, :ok}
    end

    test "add_user_text starts a new turn, or joins the summary right after /compact" do
      normal = [%{role: "user", content: "hi"}, %{role: "assistant", content: []}]
      assert Go.add_user_text(normal, "next") == normal ++ [%{role: "user", content: "next"}]

      compacted = [%{role: "user", content: "SUMMARY"}]
      assert Go.add_user_text(compacted, "next") == [%{role: "user", content: "SUMMARY\n\nnext"}]
    end
  end

  describe "compaction" do
    test "the prompt asks for a tagged summary, no tools, and adds the focus" do
      prompt = Go.compaction_prompt("")
      assert prompt =~ "<summary></summary>"
      assert prompt =~ "Do not call any tools"
      refute prompt =~ "pay particular attention"

      assert Go.compaction_prompt("the cache numbers") =~
               "pay particular attention to: the cache numbers"
    end

    test "extract_summary takes the tagged text, falls back to the reply, rejects tool calls" do
      reply = fn text ->
        %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => text}]}
      end

      assert Go.extract_summary(reply.("Here:\n<summary>\n did X \n</summary>")) == {:ok, "did X"}
      assert Go.extract_summary(reply.("no tags")) == {:ok, "no tags"}
      assert {:error, _} = Go.extract_summary(reply.("<summary> </summary>"))
      assert {:error, _} = Go.extract_summary(%{"stop_reason" => "tool_use", "content" => []})
    end

    @tag :tmp_dir
    test "the compacted conversation is AGENTS.md plus the marked summary", %{tmp_dir: dir} do
      assert [%{role: "user", content: content}] = Go.compacted_messages("did X", dir)
      assert content =~ "<earlier_conversation_summary>"
      assert content =~ "did X\n</earlier_conversation_summary>"
      refute content =~ "project_instructions"

      File.write!(Path.join(dir, "AGENTS.md"), "Use tabs.")
      assert [%{content: content}] = Go.compacted_messages("did X", dir)
      assert content =~ "Use tabs."
      assert content =~ "<earlier_conversation_summary>"
    end

    test "the status line suggests /compact only for a large prompt" do
      small = %{"input_tokens" => 10, "output_tokens" => 1}
      large = %{"input_tokens" => 5, "cache_read_input_tokens" => 160_000, "output_tokens" => 1}

      refute Go.turn_status(1, "end_turn", small) =~ "/compact"
      assert Go.turn_status(1, "end_turn", large) =~ "large context: /compact to shrink it"
    end
  end
end
