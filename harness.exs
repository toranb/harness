# go: a tiny single-file agent harness over the Claude Messages API.
# All gas, no brakes: tools run with your permissions and nothing asks first.
#
#   source .env
#   elixir harness.exs                       # prompts at >
#   elixir harness.exs "your prompt here"
#   elixir harness.exs --debug "your prompt"
#
# Tests: elixir harness_test.exs
# Pinned so every fresh install resolves the same Req.
Mix.install([{:req, "0.7.5"}])

defmodule Go do
  @moduledoc """
  A bare-bones agent loop over the Claude Messages API with four
  client-side tools: Read, Write, Edit and WebFetch, plus Bash, which runs
  any command with the user's own shell and permissions. Nothing asks
  before a tool runs.
  """

  @tools [
    %{
      name: "Read",
      description:
        "Read a file from the local filesystem and return its contents " <>
          "(truncated to 50,000 characters; for larger files, find the part you need " <>
          "with grep -n and print it with sed -n in Bash).",
      input_schema: %{
        type: "object",
        properties: %{file_path: %{type: "string", description: "Path of the file to read"}},
        required: ["file_path"],
        additionalProperties: false
      },
      strict: true
    },
    %{
      name: "Write",
      description:
        "Write content to a file on the local filesystem, overwriting it if it exists.",
      input_schema: %{
        type: "object",
        properties: %{
          file_path: %{type: "string", description: "Path of the file to write"},
          content: %{type: "string", description: "Full content to write to the file"}
        },
        required: ["file_path", "content"],
        additionalProperties: false
      },
      strict: true
    },
    %{
      name: "Edit",
      description:
        "Replace one exact occurrence of old_string with new_string in a file. " <>
          "old_string must match the file exactly (including whitespace) and appear exactly once; " <>
          "include surrounding lines to make it unique. Read the file first.",
      input_schema: %{
        type: "object",
        properties: %{
          file_path: %{type: "string", description: "Path of the file to edit"},
          old_string: %{type: "string", description: "Exact text to replace"},
          new_string: %{type: "string", description: "Replacement text"}
        },
        required: ["file_path", "old_string", "new_string"],
        additionalProperties: false
      },
      strict: true
    },
    %{
      name: "WebFetch",
      description:
        "Fetch a URL over HTTP(S) with a GET request and return the response body " <>
          "(truncated to 50,000 characters).",
      input_schema: %{
        type: "object",
        properties: %{url: %{type: "string", description: "Fully qualified http(s) URL to fetch"}},
        required: ["url"],
        additionalProperties: false
      },
      strict: true
    },
    %{
      name: "Bash",
      description:
        "Run a command with `bash -c` in the working directory and return its output " <>
          "(stdout and stderr together, truncated to 50,000 characters) followed by the " <>
          "exit code. A non-zero exit is reported as an error. Pipes, redirects, &&, globs " <>
          "and variables all work. Use it for git, curl, grep or rg, mix, and any other " <>
          "installed program. Each call is a fresh, non-interactive shell: cd and exported " <>
          "variables don't carry over, stdin is empty, and there is no editor or pager " <>
          "(pass -m to git commit). A command still running after `timeout` seconds " <>
          "(default 120, max 600) is killed, so start servers in the background.",
      input_schema: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "The bash command to run"},
          timeout: %{
            type: "integer",
            description: "Seconds to wait before killing the command (default 120, max 600)"
          }
        },
        required: ["command"],
        additionalProperties: false
      },
      strict: true
    }
  ]

  # The most output tokens one reply may use. This limits a single reply, not
  # the conversation (the context window is far larger). 128,000 is the
  # maximum Haiku 5.5, Sonnet 5.5 and Opus 5.5 accept; anything higher is a
  # 400. You pay for the tokens a reply actually uses, not for this limit.
  @max_tokens 128_000

  # Every tool result is cut to this many characters, so one big file or web
  # page can't flood the context window. truncate/1 adds a note when it cuts.
  @max_output 50_000

  # Bash kills a command after this many seconds unless the model asks for
  # a different timeout, which is capped at @bash_max_timeout.
  @bash_timeout 120
  @bash_max_timeout 600

  # Bash keeps at most this many bytes of a command's output while it runs,
  # so something like `yes` can't fill memory before the timeout. It is
  # well above @max_output, which truncate/1 then cuts to.
  @bash_max_bytes 1_000_000

  # Set for every Bash command so nothing waits for an editor, pager or
  # password prompt that the harness can't show.
  @bash_env [
    {"GIT_EDITOR", "true"},
    {"EDITOR", "true"},
    {"VISUAL", "true"},
    {"GIT_PAGER", "cat"},
    {"PAGER", "cat"},
    {"GIT_TERMINAL_PROMPT", "0"}
  ]

  # Programs the system prompt reports as installed (when they are), so the
  # model doesn't have to guess what the machine has.
  @known_programs ~w(git curl rg grep sed awk find jq make mix elixir erl node npm
                     python3 docker gh)

  # What you can type at the > prompt besides a message, as shown by /help.
  # To add a command, add it here and handle it in next_prompt/2 (and in
  # start/1 if it should work before the first message).
  @commands [
    {"/help", "list these commands"},
    {"/compact [focus]", "summarize the conversation to free up context (optional focus)"},
    {"exit, quit, Ctrl-D", "end the session"}
  ]

  # The status line suggests /compact once a prompt is this big. It is only
  # a hint: nothing compacts until you type the command.
  @compact_hint_tokens 150_000

  @doc "The tool definitions sent to the API with every request."
  def tools, do: @tools

  @doc """
  The harness instructions, sent as the top-level `system` field.

  The tool names come from `@tools`, so this list can't drift from what the
  API actually receives; how to use each tool lives in its own description.
  The machine facts come from `machine/0`, which is detected once per
  session. The text depends only on `cwd` and those facts, so it is
  byte-identical for every request in a session, which keeps it cacheable
  (see `request_body/2`).
  """
  def system_prompt(cwd, machine \\ machine()) do
    """
    You are a coding agent running inside "go", a small custom harness written in
    Elixir. It is not Claude Code. Your only tools are
    #{Enum.map_join(@tools, ", ", & &1.name)};
    the harness runs them on the user's machine with the user's permissions, and
    nothing asks the user first.

    Working directory: #{cwd}
    Relative paths resolve against it; prefer them.

    #{machine_text(machine)}

    Bash runs each command in a fresh, non-interactive shell in the working
    directory: cd and variables don't carry over, stdin is empty, and there is
    no editor or pager. Use Read, Edit and Write for files rather than cat, sed
    or heredocs.

    After changing Elixir code, run mix compile and mix test with Bash to verify
    it rather than assuming it works.

    If a program you need isn't installed, say so instead of guessing. Changes
    to this harness's own code take effect only in the next session.

    Keep replies short and plain; the user reads them in a terminal.
    """
  end

  @doc """
  What the system prompt says about the machine: the OS, the bash version,
  and which of `@known_programs` are installed. Detected on the first call
  and kept for the rest of the session, so the system prompt (and its cache
  entry) doesn't change if the agent installs something.
  """
  def machine do
    case :persistent_term.get({__MODULE__, :machine}, nil) do
      nil ->
        machine = detect_machine()
        :persistent_term.put({__MODULE__, :machine}, machine)
        machine

      machine ->
        machine
    end
  end

  defp detect_machine do
    {os, version} =
      case :os.type() do
        {:unix, :darwin} -> {"macOS", nil}
        {:unix, :linux} -> {"Linux", :os.version() |> Tuple.to_list() |> Enum.join(".")}
        {_, name} -> {to_string(name), nil}
      end

    {bash_version, _} = System.cmd("bash", ["-c", "echo -n ${BASH_VERSION%%(*}"])

    %{
      os: os,
      os_version: version,
      bash: bash_version,
      programs: Enum.filter(@known_programs, &System.find_executable/1)
    }
  end

  # The machine facts as prompt text, wrapped at 80 characters like the rest.
  defp machine_text(machine) do
    os = Enum.join(Enum.reject([machine.os, machine.os_version], &is_nil/1), " ")

    macos =
      if machine.os == "macOS",
        do:
          " sed, grep, find and date are the BSD versions (sed -i needs an argument, " <>
            "grep has no -P) and there is no timeout command.",
        else: ""

    wrap(
      "Machine: #{os}, bash #{machine.bash}." <>
        macos <> " Installed: #{Enum.join(machine.programs, ", ")}."
    )
  end

  defp wrap(text, width \\ 80) do
    text
    |> String.split(" ")
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | rest] ->
        if String.length(line) + 1 + String.length(word) <= width,
          do: [line <> " " <> word | rest],
          else: [word, line | rest]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @doc """
  Builds the first user message of a session.

  If the working directory has an AGENTS.md, it goes in front of the prompt,
  so the project's own instructions stay in context for the whole conversation.
  """
  def first_message(prompt, cwd) do
    path = Path.join(cwd, "AGENTS.md")

    case File.read(path) do
      {:ok, agents_md} ->
        """
        <project_instructions source="AGENTS.md">
        The project's AGENTS.md is below. Follow it as instructions from the user
        for this project, unless it conflicts with the user's message.

        #{String.trim(agents_md)}
        </project_instructions>

        #{prompt}\
        """

      {:error, _} ->
        prompt
    end
  end

  @doc """
  Builds the JSON body for one Messages API request.

  Prompt caching: the API renders tools -> system -> messages, and a cache
  entry covers everything up to a breakpoint. There are two breakpoints:

    1. explicit, on the system prompt: caches tools + system, which are the
       same for every request (and every session in the same folder);
    2. automatic (top-level `cache_control`): the API puts it on the last
       block and moves it forward as the conversation grows, so each request
       reads the previous request's prefix from cache.

  Anything that changes those bytes (tool list, system text, model) misses.
  """
  def request_body(messages, cwd) do
    %{
      model: System.get_env("API_MODEL", "claude-haiku-5-5"),
      max_tokens: @max_tokens,
      cache_control: %{type: "ephemeral"},
      system: [
        %{type: "text", text: system_prompt(cwd), cache_control: %{type: "ephemeral"}}
      ],
      tools: @tools,
      messages: messages
    }
  end

  # ---------------------------------------------------------------------------
  # The agent loop
  # ---------------------------------------------------------------------------

  @doc """
  Starts an interactive session. This is the whole agent loop:

    1. send the conversation to the model (`call_model/2`, streamed)
    2. if the model asked for tools, run them (`run_tools/1`), append the
       results to the conversation and go back to 1
    3. otherwise its turn is over: read the user's next message
       (`read_user_input/0`), append it and go back to 1

  The conversation (`messages`) grows with every request, and every request
  sends all of it. `/compact` at the `>` prompt replaces it with a summary
  (`compact/3`). A blank prompt asks for one at `>`. Type `exit` or press
  Ctrl-D to quit.
  """
  def run(prompt) when is_binary(prompt) do
    {:ok, _} = Application.ensure_all_started(:req)
    start(parse_input(prompt))
  end

  # Before the first message only /help does anything; other commands
  # explain why not and ask again.
  defp start({:message, text}),
    do: loop([%{role: "user", content: first_message(text, File.cwd!())}], 1)

  defp start(:exit), do: :ok
  defp start(:blank), do: start(read_user_input())

  defp start({:command, "help", _}) do
    IO.puts(help_text())
    start(read_user_input())
  end

  defp start({:command, "compact", _}) do
    IO.puts("/compact needs a conversation first; send a message.")
    start(read_user_input())
  end

  defp start({:command, name, _}) do
    IO.puts(unknown_command(name))
    start(read_user_input())
  end

  # One pass = one request to the model. `turn` counts requests, for display.
  defp loop(messages, turn) do
    case call_model(messages) do
      {:ok, response} ->
        # The reply's text was already printed as it streamed in.
        IO.puts(turn_status(turn, response["stop_reason"], response["usage"]))
        # Append the assistant's content unchanged (thinking blocks included).
        messages = messages ++ [%{role: "assistant", content: response["content"]}]

        if response["stop_reason"] == "tool_use" do
          results = run_tools(response["content"])
          loop(messages ++ [%{role: "user", content: results}], turn + 1)
        else
          next_prompt(messages, turn + 1)
        end

      {:error, reason} ->
        IO.puts("\n[api error] #{reason}")
        IO.puts("The conversation is kept. Press Enter to retry this request, or type exit.")

        case read_line("retry> ") do
          answer when answer in [:eof, "exit", "quit"] -> :ok
          _ -> loop(messages, turn)
        end
    end
  end

  # The model finished its turn: wait for the user's next message or command.
  defp next_prompt(messages, turn) do
    case read_user_input() do
      {:message, text} ->
        loop(add_user_text(messages, text), turn)

      {:command, "compact", focus} ->
        case compact(messages, focus, turn) do
          {:ok, compacted} ->
            next_prompt(compacted, turn + 1)

          {:error, reason} ->
            IO.puts("[compact failed] #{reason}\nThe conversation is unchanged.")
            next_prompt(messages, turn + 1)
        end

      {:command, "help", _} ->
        IO.puts(help_text())
        next_prompt(messages, turn)

      {:command, name, _} ->
        IO.puts(unknown_command(name))
        next_prompt(messages, turn)

      :exit ->
        :ok
    end
  end

  @doc """
  The `/help` output: one line per entry in `@commands`, aligned. Anything
  else typed at `>` is sent to the model as a message.
  """
  def help_text do
    width = @commands |> Enum.map(fn {usage, _} -> String.length(usage) end) |> Enum.max()

    lines =
      for {usage, description} <- @commands,
          do: "  #{String.pad_trailing(usage, width)}  #{description}"

    Enum.join(["Commands:" | lines] ++ ["Anything else you type is sent to the model."], "\n")
  end

  defp unknown_command(name), do: "Unknown command /#{name}. Type /help for the list."

  @doc """
  Adds the user's text to the conversation.

  Normally that is a new user message. Right after `/compact` the
  conversation is a single user message holding the summary; the API wants
  user and assistant turns to alternate, so the text joins that message
  instead of following it.
  """
  def add_user_text(messages, text) do
    case List.last(messages) do
      %{role: "user", content: summary} when is_binary(summary) ->
        List.replace_at(messages, -1, %{role: "user", content: summary <> "\n\n" <> text})

      _ ->
        messages ++ [%{role: "user", content: text}]
    end
  end

  # ---------------------------------------------------------------------------
  # Compaction (/compact)
  # ---------------------------------------------------------------------------

  @doc """
  Replaces the conversation with a summary of it, so a long session can keep
  going without hitting the context limit. Runs only when you type
  `/compact [focus]` at the `>` prompt, never automatically, and only between
  turns, so no tool call is ever left without its result.

  1. Send the whole conversation plus one more user message asking for a
     summary (`compaction_prompt/1`). The prefix is already cached, so this
     request is cheap.
  2. Take the text inside `<summary>` tags (`extract_summary/1`).
  3. Start a new conversation holding only AGENTS.md (if any) and the
     summary (`compacted_messages/2`). Your next message is added to it.

  Nothing from before the summary is replayed: no earlier turns, tool
  results or thinking blocks. The summary is all the model keeps, which is
  why the prompt says exactly what to preserve. The next request starts a
  new cache entry for the conversation; tools + system stay cached.

  Returns `{:ok, new_messages}`, or `{:error, reason}` with the conversation
  left as it was.
  """
  def compact(messages, focus, turn) do
    request = messages ++ [%{role: "user", content: compaction_prompt(focus)}]
    IO.puts("[compact] summarizing #{length(messages)} messages...")

    with {:ok, response} <- call_model(request, show_text: false),
         IO.puts("[compact] " <> turn_status(turn, response["stop_reason"], response["usage"])),
         {:ok, summary} <- extract_summary(response) do
      IO.puts("\n--- summary (the model's only memory of the session from here on) ---")
      IO.puts(summary)
      IO.puts("--- end of summary ---")
      IO.puts("[compact] the conversation is now this summary; your next message continues it")
      {:ok, compacted_messages(summary, File.cwd!())}
    end
  end

  @doc """
  The request that asks the model to summarize the conversation.

  This is the summarization prompt Anthropic suggests for client-side
  compaction. It lists what a summary must keep so the work can continue
  without being redone, and its last sentence stops the model from calling
  a tool, since the request still carries the tool list. `focus` is
  whatever you typed after `/compact`.
  """
  def compaction_prompt(focus) do
    base =
      "Summarize the transcript inside <summary></summary> tags. Include relevant information " <>
        "in the summary such that this conversation will be continued by a new context window " <>
        "without needing to redo work or be reprovided with relevant constraints or context. " <>
        "Be sure to preserve: (1) any difficulties or problems that came up, and how they were " <>
        "handled or resolved; (2) any possibilities, options, or approaches that were raised, " <>
        "tried, or set aside, and why; (3) anything that was asked for, decided, agreed, ruled " <>
        "out, or established as a preference, constraint, or boundary - stated exactly; " <>
        "(4) exactly where things stand now - what has been covered, settled, or completed so " <>
        "far; (5) anything still open, unresolved, promised, or expected to happen next; " <>
        "(6) specific details that would be hard to reconstruct - names, numbers, dates, exact " <>
        "wording, links or references - kept exactly. Be complete on these even at the cost of " <>
        "length; keep everything else concise. Weight the two voices differently: keep what the " <>
        "user said, asked for, shared, or established carefully and close to their own words; " <>
        "your own explanations and reasoning can be condensed much further, to what they " <>
        "concluded or produced - as long as nothing in the six items above is dropped. Do not " <>
        "call any tools while writing this summary; respond with text only."

    case String.trim(focus) do
      "" -> base
      focus -> base <> "\n\nThe user asked the summary to pay particular attention to: " <> focus
    end
  end

  @doc """
  Pulls the summary out of the model's reply: the text inside
  `<summary>` tags, or the whole reply if the tags are missing.
  """
  def extract_summary(%{"stop_reason" => "tool_use"}),
    do: {:error, "the model called a tool instead of writing a summary"}

  def extract_summary(%{"content" => content}) do
    text = for(%{"type" => "text", "text" => t} <- content, do: t) |> Enum.join("\n")

    summary =
      case Regex.run(~r{<summary>(.*)</summary>}s, text) do
        [_, inside] -> String.trim(inside)
        nil -> String.trim(text)
      end

    if summary == "", do: {:error, "the model returned an empty summary"}, else: {:ok, summary}
  end

  @doc """
  The conversation after `/compact`: one user message with AGENTS.md (if
  any, via `first_message/2`) and the summary, marked so the model knows
  what it is. `add_user_text/2` appends your next message to it.
  """
  def compacted_messages(summary, cwd) do
    block = """
    <earlier_conversation_summary>
    This session was compacted: the conversation so far was replaced by this
    summary of it. Continue the work from here.

    #{summary}
    </earlier_conversation_summary>\
    """

    [%{role: "user", content: first_message(block, cwd)}]
  end

  @doc """
  Sends the conversation to the Messages API and streams the reply.

  With `stream: true` the API sends the reply as server-sent events while it
  is being generated, instead of one JSON body at the end. Text is printed
  the moment it arrives (pass `show_text: false` to stay quiet), and the
  events are put back together into the same response the non-streaming API
  returns: `%{"content" => blocks, "stop_reason" => _, "usage" => _}`. The
  rest of the loop never needs to know the reply was streamed.

  Returns `{:ok, response}` or `{:error, reason}`. Errors are returned rather
  than raised, so a failed request doesn't end the session. With `--debug`,
  prints the full request body first.
  """
  def call_model(messages, opts \\ []) do
    show_text? = Keyword.get(opts, :show_text, true)
    body = messages |> request_body(File.cwd!()) |> Map.put(:stream, true)

    if Application.get_env(:go, :debug, false) do
      IO.inspect(body,
        label: "\n[debug] POST /v1/messages (#{length(messages)} messages)",
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity
      )
    end

    # Req calls this with each chunk of the response body as it arrives. The
    # stream state (see new_stream/0) is kept in the response's private map.
    on_chunk = fn {:data, chunk}, {req, resp} ->
      resp =
        if resp.status == 200 do
          stream = Req.Response.get_private(resp, :stream, new_stream())
          {stream, text} = consume_chunk(stream, chunk)
          if show_text?, do: IO.write(text)
          Req.Response.put_private(resp, :stream, stream)
        else
          # An error response is one plain JSON body, not events: keep it raw.
          Req.Response.update_private(resp, :error_body, chunk, &(&1 <> chunk))
        end

      {:cont, {req, resp}}
    end

    result =
      Req.post("https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", System.fetch_env!("API_KEY")},
          {"anthropic-version", "2026-10-21"}
        ],
        json: body,
        receive_timeout: 600_000,
        into: on_chunk
      )

    case result do
      {:ok, %{status: 200} = resp} ->
        finish_stream(Req.Response.get_private(resp, :stream, new_stream()))

      {:ok, resp} ->
        {:error, "HTTP #{resp.status}: #{Req.Response.get_private(resp, :error_body, "")}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming: rebuilding a response from server-sent events
  # ---------------------------------------------------------------------------
  #
  # A streamed reply arrives as events like these, one per blank-line-separated
  # chunk of text (`event:` names the type, `data:` is JSON):
  #
  #   message_start        usage for the prompt (input and cache tokens)
  #   content_block_start  a new block at `index`: text, tool_use or thinking
  #   content_block_delta  a piece of that block: text_delta, input_json_delta,
  #                        thinking_delta or signature_delta
  #   content_block_stop   the block at `index` is complete
  #   message_delta        the stop_reason and the output token count
  #   message_stop         the end
  #   ping / error         keep-alive / something went wrong mid-stream

  @doc """
  The state of a reply while it streams in:

    * `buffer`: the start of an event cut off at the end of the last chunk
    * `blocks`: each content block built so far, by its `index`
    * `json`: each tool_use block's input, which arrives as pieces of a
      JSON string and is only decoded once the block is complete
    * `stop_reason`, `usage`, `error`: filled in by the events that carry them
  """
  def new_stream,
    do: %{buffer: "", blocks: %{}, json: %{}, stop_reason: nil, usage: %{}, error: nil}

  @doc """
  Feeds one network chunk into the stream. A chunk can end in the middle of
  an event, so only complete events (ending in a blank line) are applied and
  the rest waits in `buffer` for the next chunk. Returns the new state and
  the text to print.
  """
  def consume_chunk(stream, chunk) do
    [rest | complete] = String.split(stream.buffer <> chunk, "\n\n") |> Enum.reverse()

    complete
    |> Enum.reverse()
    |> Enum.reduce({%{stream | buffer: rest}, ""}, fn raw_event, {stream, printed} ->
      {stream, text} = apply_event(stream, decode_event(raw_event))
      {stream, printed <> text}
    end)
  end

  # The JSON on an event's `data:` line (the `event:` line repeats its type).
  defp decode_event(raw_event) do
    case for("data: " <> json <- String.split(raw_event, "\n"), do: json) do
      [] -> %{}
      lines -> JSON.decode!(Enum.join(lines, "\n"))
    end
  end

  @doc """
  Applies one event to the stream state. Returns the new state and the text
  to print: the text of a `text_delta`, and a newline when a text block ends.
  Event and delta types it doesn't know about are ignored.
  """
  def apply_event(stream, %{"type" => "message_start", "message" => message}),
    do: {%{stream | usage: message["usage"] || %{}}, ""}

  def apply_event(stream, %{"type" => "content_block_start", "index" => i} = event),
    do: {put_in(stream.blocks[i], event["content_block"]), ""}

  def apply_event(stream, %{"type" => "content_block_delta", "index" => i, "delta" => delta}) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        {append_to_block(stream, i, "text", text), text}

      %{"type" => "input_json_delta", "partial_json" => piece} ->
        {%{stream | json: Map.update(stream.json, i, piece, &(&1 <> piece))}, ""}

      %{"type" => "thinking_delta", "thinking" => piece} ->
        {append_to_block(stream, i, "thinking", piece), ""}

      %{"type" => "signature_delta", "signature" => piece} ->
        {append_to_block(stream, i, "signature", piece), ""}

      _ ->
        {stream, ""}
    end
  end

  def apply_event(stream, %{"type" => "content_block_stop", "index" => i}) do
    case stream.blocks[i] do
      # The input arrived as JSON text in pieces; decode it now it's complete.
      # A tool called with no arguments sends no pieces at all.
      %{"type" => "tool_use"} ->
        input =
          case Map.get(stream.json, i, "") do
            "" -> %{}
            json -> JSON.decode!(json)
          end

        {put_in(stream.blocks[i]["input"], input), ""}

      %{"type" => "text"} ->
        {stream, "\n"}

      _ ->
        {stream, ""}
    end
  end

  def apply_event(stream, %{"type" => "message_delta"} = event) do
    usage = for {key, value} <- event["usage"] || %{}, value != nil, into: %{}, do: {key, value}

    {%{
       stream
       | stop_reason: event["delta"]["stop_reason"],
         usage: Map.merge(stream.usage, usage)
     }, ""}
  end

  def apply_event(stream, %{"type" => "error", "error" => error}),
    do: {%{stream | error: error}, ""}

  # ping, message_stop, and any event type added to the API later.
  def apply_event(stream, _event), do: {stream, ""}

  defp append_to_block(stream, i, key, piece),
    do: update_in(stream.blocks[i][key], &((&1 || "") <> piece))

  @doc """
  Turns a finished stream into a response, ordering the blocks by index.
  Returns an error if the API sent an error event, or if the stream ended
  before `message_delta` delivered a stop_reason (a dropped connection).
  """
  def finish_stream(%{error: %{} = error}),
    do: {:error, "stream error: #{error["type"]}: #{error["message"]}"}

  def finish_stream(%{stop_reason: nil}),
    do: {:error, "the stream ended before the reply was complete"}

  def finish_stream(stream) do
    content = stream.blocks |> Enum.sort_by(fn {i, _} -> i end) |> Enum.map(fn {_, b} -> b end)
    {:ok, %{"content" => content, "stop_reason" => stream.stop_reason, "usage" => stream.usage}}
  end

  @doc """
  Formats the status line printed after every model response: the request
  number, why the model stopped, and how big the conversation now is.

  The prompt size is the sum of three usage fields: tokens read from cache,
  tokens written to cache, and uncached input. Watching it grow each turn is
  the clearest picture of how an agent's context fills up.
  """
  def turn_status(turn, stop_reason, usage) do
    read = usage["cache_read_input_tokens"] || 0
    written = usage["cache_creation_input_tokens"] || 0
    uncached = usage["input_tokens"] || 0

    prompt = read + written + uncached

    hint =
      if prompt >= @compact_hint_tokens, do: " | large context: /compact to shrink it", else: ""

    "[turn #{turn}] stop_reason=#{stop_reason} | prompt #{prompt} tokens " <>
      "(cache read #{read}, cache write #{written}, uncached #{uncached}) | " <>
      "output #{usage["output_tokens"] || 0} tokens" <> hint
  end

  # Runs every tool call in the model's response, in order, and returns one
  # tool_result per call. They all go back together in a single user message.
  defp run_tools(content) do
    for %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} <- content do
      IO.puts("-> #{name} #{inspect(input, printable_limit: 200)}")

      {output, error?} =
        try do
          execute_tool(name, input)
        rescue
          e -> {Exception.message(e), true}
        end

      IO.puts("<- " <> result_summary(output, error?))
      %{type: "tool_result", tool_use_id: id, content: output, is_error: error?}
    end
  end

  @doc """
  One-line summary of a tool result for the terminal: ok/error, its size, and
  the start of its first line. The model always gets the full result.
  """
  def result_summary(output, error?) do
    first_line = output |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 100)
    "#{if error?, do: "error", else: "ok"}, #{String.length(output)} chars: #{first_line}"
  end

  @doc """
  Reads the user's next input at the `>` prompt, skipping blank lines.
  Returns what `parse_input/1` returns (never `:blank`); Ctrl-D is `:exit`.
  """
  def read_user_input do
    case read_line("\n> ") do
      :eof ->
        :exit

      line ->
        case parse_input(line) do
          :blank -> read_user_input()
          input -> input
        end
    end
  end

  @doc """
  Decides what a line typed at `>` is:

    * `:blank` for an empty line
    * `:exit` for `exit` or `quit`
    * `{:command, name, rest}` for a slash command such as `/compact focus on X`
    * `{:message, text}` for anything else, which goes to the model

  Only a slash followed by letters is a command, so a message that starts
  with a path such as `/home/me/app` still goes to the model.
  """
  def parse_input(line) do
    text = String.trim(line)

    cond do
      text == "" -> :blank
      text in ["exit", "quit"] -> :exit
      match = Regex.run(~r{\A/([a-z]+)(?:\s+(.*))?\z}s, text) -> command(match)
      true -> {:message, text}
    end
  end

  defp command([_, name]), do: {:command, name, ""}
  defp command([_, name, rest]), do: {:command, name, rest}

  defp read_line(label) do
    case IO.gets(label) do
      line when is_binary(line) -> String.trim(line)
      _ -> :eof
    end
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  @doc """
  Runs one tool call by name and returns `{output, is_error}`.

  A clause may also raise: `run_tools/1` turns the exception message into an
  error result, so the model sees what went wrong and can try again.
  """
  def execute_tool("Read", %{"file_path" => path}), do: {truncate(File.read!(path)), false}

  def execute_tool("Write", %{"file_path" => path, "content" => body}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    {"Wrote #{byte_size(body)} bytes to #{path}", false}
  end

  def execute_tool("Edit", %{"file_path" => path, "old_string" => old, "new_string" => new}) do
    if old == "", do: raise("old_string must not be empty")
    text = File.read!(path)

    case length(:binary.matches(text, old)) do
      0 -> raise "old_string not found in #{path}"
      1 -> File.write!(path, String.replace(text, old, new, global: false))
      n -> raise "old_string matches #{n} times in #{path}; include more context"
    end

    {"Edited #{path}", false}
  end

  def execute_tool("WebFetch", %{"url" => url}) do
    r = Req.get!(url, decode_body: false, receive_timeout: 30_000)
    {"HTTP #{r.status}\n\n" <> truncate(to_string(r.body)), false}
  end

  def execute_tool("Bash", %{"command" => command} = input) do
    timeout = (input["timeout"] || @bash_timeout) |> max(1) |> min(@bash_max_timeout)
    {out, status} = run_bash(command, timeout)
    # Binary output would make the request invalid JSON, so bad bytes become �.
    output = out |> String.replace_invalid() |> String.trim_trailing() |> truncate()

    case status do
      :timeout -> {output <> "\n\n(killed after #{timeout} seconds)", true}
      code -> {output <> "\n\n(exit #{code})", code != 0}
    end
  end

  def execute_tool(name, _input), do: {"Unknown tool: #{name}", true}

  # Runs `bash -c command` in a Port so it can be killed at the deadline
  # (System.cmd has no timeout, and macOS has no `timeout` command). The
  # first line of the script points stdin at /dev/null, so a command that
  # reads input gets EOF instead of waiting forever.
  defp run_bash(command, timeout) do
    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-c", "exec </dev/null\n" <> command],
        env: for({k, v} <- @bash_env, do: {String.to_charlist(k), String.to_charlist(v)})
      ])

    deadline = System.monotonic_time(:millisecond) + timeout * 1000
    collect_output(port, deadline, "")
  end

  defp collect_output(port, deadline, acc) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        acc = if byte_size(acc) < @bash_max_bytes, do: acc <> data, else: acc
        collect_output(port, deadline, acc)

      {^port, {:exit_status, code}} ->
        {acc, code}
    after
      wait ->
        kill_port(port)
        {acc, :timeout}
    end
  end

  # Kills the shell and the processes it started (its direct children; a
  # grandchild that detached itself can outlive it).
  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("pkill", ["-KILL", "-P", to_string(pid)], stderr_to_stdout: true)
        System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  # Drops anything the port sent before it closed.
  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  @doc """
  Cuts text to `@max_output` characters, with a note saying so, so the model
  knows it is not seeing everything.
  """
  def truncate(text) do
    length = String.length(text)

    if length <= @max_output do
      text
    else
      String.slice(text, 0, @max_output) <>
        "\n\n(truncated: showing the first #{@max_output} of #{length} characters; " <>
        "use grep -n and sed -n with Bash to see the part you need)"
    end
  end
end

# Entry point: `elixir harness.exs [--debug] [prompt...]`. With no prompt,
# Go.run/1 asks for one at `>`. harness_test.exs loads this file with
# :no_main set so it can test the Go module without starting a session.
unless Application.get_env(:go, :no_main, false) do
  {opts, args, _} = OptionParser.parse(System.argv(), strict: [debug: :boolean])
  Application.put_env(:go, :debug, Keyword.get(opts, :debug, false))
  Go.run(Enum.join(args, " "))
end
