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

  describe "Bash tool" do
    test "runs a real shell: pipes, &&, variables, and the exit code" do
      {output, error?} =
        Go.execute_tool("Bash", %{"command" => "x=hi; echo $x | tr a-z A-Z && echo ok"})

      refute error?
      assert output == "HI\nok\n\n(exit 0)"
    end

    test "a non-zero exit is an error and stderr is included" do
      assert {"oops\n\n(exit 3)", true} =
               Go.execute_tool("Bash", %{"command" => "echo oops >&2; exit 3"})
    end

    @tag :tmp_dir
    test "runs in the working directory", %{tmp_dir: dir} do
      File.cd!(dir, fn ->
        {output, false} = Go.execute_tool("Bash", %{"command" => "pwd -P"})
        assert output =~ Path.basename(dir)
      end)
    end

    test "stdin is empty, so a command that reads input doesn't hang" do
      assert {"0\n\n(exit 0)", false} =
               Go.execute_tool("Bash", %{"command" => "cat | wc -c | tr -d ' '"})
    end

    test "kills a command that runs past its timeout" do
      started = System.monotonic_time(:millisecond)

      {output, true} =
        Go.execute_tool("Bash", %{"command" => "echo started; sleep 30", "timeout" => 1})

      assert output =~ "started"
      assert output =~ "(killed after 1 seconds)"
      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "turns invalid UTF-8 into replacement characters" do
      {output, false} = Go.execute_tool("Bash", %{"command" => "printf 'a\\377b'"})
      assert String.valid?(output)
      assert output =~ "a\uFFFDb"
    end

    @tag :tmp_dir
    test "returns as soon as the command ends, leaving a background job running",
         %{tmp_dir: dir} do
      File.cd!(dir, fn ->
        started = System.monotonic_time(:millisecond)

        # The background job holds the output pipe for 3 seconds; the command
        # itself is done at once.
        {output, false} =
          Go.execute_tool("Bash", %{
            "command" =>
              "(sleep 3; echo late) & echo now; (sleep 1; echo done > bg.txt) > /dev/null 2>&1 &",
            "timeout" => 10
          })

        assert System.monotonic_time(:millisecond) - started < 2_000
        assert output == "now\n\n(exit 0)"

        Process.sleep(1_500)
        assert File.read!("bg.txt") == "done\n"
      end)
    end

    test "reports the exit code from exit, and from a script whose own EXIT trap replaces ours" do
      assert {"bye\n\n(exit 4)", true} =
               Go.execute_tool("Bash", %{"command" => "echo bye; exit 4"})

      assert {"mine\n\n(exit 5)", true} =
               Go.execute_tool("Bash", %{"command" => "trap 'echo mine' EXIT; exit 5"})
    end

    test "the harness's API key is not in a command's environment" do
      System.put_env("API_KEY", "secret-for-test")

      try do
        assert {"unset\n\n(exit 0)", false} =
                 Go.execute_tool("Bash", %{"command" => "echo ${API_KEY-unset}"})
      after
        System.delete_env("API_KEY")
      end
    end

    @tag :tmp_dir
    test "git never waits for an editor", %{tmp_dir: dir} do
      File.cd!(dir, fn ->
        {_, 0} = System.cmd("git", ["init", "-q"])
        {output, true} = Go.execute_tool("Bash", %{"command" => "git commit --allow-empty"})
        assert output =~ "(exit 1)"
      end)
    end
  end

  describe "instruction context" do
    test "system prompt lists exactly the tools the API receives" do
      prompt = Go.system_prompt("/some/project")

      assert prompt =~ "Working directory: /some/project"
      names = Enum.map_join(Go.tools(), ", ", & &1.name)
      assert prompt =~ "Your only tools are\n#{names};"
    end

    test "system prompt states the machine and wraps at 80 characters" do
      machine = %{
        os: "macOS",
        os_version: nil,
        bash: "3.2.57",
        programs: ~w(git curl rg grep sed awk find jq make mix elixir erl node npm python3)
      }

      prompt = Go.system_prompt("/some/project", machine)

      assert prompt =~ "Machine: macOS, bash 3.2.57."
      assert prompt =~ "BSD versions"
      assert String.replace(prompt, "\n", " ") =~ "Installed: git, curl, rg,"

      for line <- String.split(prompt, "\n") do
        assert String.length(line) <= 80, "system prompt line is too long: #{line}"
      end
    end

    test "detects this machine once per session" do
      machine = Go.machine()

      assert machine.bash =~ ~r/^\d+\.\d+/
      assert "git" in machine.programs
      assert Go.machine() == machine
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

    test "asks for the largest reply the current models accept" do
      assert Go.request_body([%{role: "user", content: "hi"}], "/p").max_tokens == 128_000
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

    test "/help lists every command and works before the first message" do
      output = capture_io("/help\n/nope\nexit\n", fn -> send(self(), {:result, Go.run("")}) end)

      assert output =~ Go.help_text()
      assert output =~ "Unknown command /nope. Type /help for the list."
      assert_received {:result, :ok}

      for usage <- ["/help", "/compact [focus]", "exit, quit, Ctrl-D"] do
        assert Go.help_text() =~ usage
      end
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

  describe "streaming" do
    # Builds a server-sent-events body like the API's from a list of events.
    defp sse(events) do
      Enum.map_join(events, fn event ->
        "event: #{event["type"]}\ndata: #{JSON.encode!(event)}\n\n"
      end)
    end

    defp delta(i, delta), do: %{"type" => "content_block_delta", "index" => i, "delta" => delta}

    @reply [
      %{
        "type" => "message_start",
        "message" => %{"usage" => %{"input_tokens" => 4, "cache_read_input_tokens" => 2000}}
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig123"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "ping"},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "Let me "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "look."}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "tu_1",
          "name" => "Read",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"file_"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "path\": \"a.ex\"}"}
      },
      %{"type" => "content_block_stop", "index" => 2},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 42}
      },
      %{"type" => "message_stop"}
    ]

    defp run_stream(body, chunk_size) do
      chunks = for <<chunk::binary-size(^chunk_size) <- body>>, do: chunk
      tail = binary_part(body, length(chunks) * chunk_size, rem(byte_size(body), chunk_size))

      {stream, printed} =
        Enum.reduce(chunks ++ [tail], {Go.new_stream(), ""}, fn chunk, {stream, printed} ->
          {stream, text} = Go.consume_chunk(stream, chunk)
          {stream, printed <> text}
        end)

      {Go.finish_stream(stream), printed}
    end

    test "rebuilds the full response and prints only the text" do
      {{:ok, response}, printed} = run_stream(sse(@reply), byte_size(sse(@reply)))

      assert printed == "Let me look.\n"
      assert response["stop_reason"] == "tool_use"

      assert response["usage"] == %{
               "input_tokens" => 4,
               "cache_read_input_tokens" => 2000,
               "output_tokens" => 42
             }

      assert response["content"] == [
               %{"type" => "thinking", "thinking" => "", "signature" => "sig123"},
               %{"type" => "text", "text" => "Let me look."},
               %{
                 "type" => "tool_use",
                 "id" => "tu_1",
                 "name" => "Read",
                 "input" => %{"file_path" => "a.ex"}
               }
             ]
    end

    test "events split across network chunks give the same result" do
      whole = run_stream(sse(@reply), byte_size(sse(@reply)))

      for size <- [1, 7, 64] do
        assert run_stream(sse(@reply), size) == whole
      end
    end

    test "a tool called with no arguments gets an empty input" do
      events = [
        %{"type" => "message_start", "message" => %{"usage" => %{}}},
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "tool_use", "id" => "t", "name" => "X", "input" => %{}}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{"output_tokens" => 3}
        }
      ]

      {{:ok, response}, ""} = run_stream(sse(events), 1000)
      assert [%{"input" => %{}}] = response["content"]
    end

    test "an error event or a cut-off stream is an error, not a reply" do
      error = [
        %{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
        }
      ]

      assert {{:error, "stream error: overloaded_error: Overloaded"}, ""} =
               run_stream(sse(error), 1000)

      # Cut off mid text block: the text printed so far, then an error.
      cut_off = Enum.take(@reply, 8)

      assert {{:error, "the stream ended before the reply was complete"}, "Let me look."} =
               run_stream(sse(cut_off), 1000)
    end

    test "unknown event and delta types are ignored" do
      events =
        List.insert_at(@reply, 7, %{"type" => "some_future_event"})
        |> List.insert_at(7, delta(1, %{"type" => "citations_delta", "citation" => %{}}))

      assert run_stream(sse(events), 1000) == run_stream(sse(@reply), 1000)
    end
  end
end
