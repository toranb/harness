# go: a tiny single-file agent harness over the Claude Messages API.
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
  A bare-bones agent loop over the Claude Messages API with
  client-side tools that mirror Claude Code's: Read, Write, Edit, WebFetch, Grep,
  plus Curl, Mix and Git, which run the native `curl`, `mix` and `git`.
  """

  # The only mix tasks the Mix tool will run.
  @mix_tasks ~w(deps.get compile test format)

  # The git subcommands the Git tool will run: enough to inspect and search
  # history (status, log, diff, show) and to make local commits (add,
  # commit, stash). Nothing that talks to a remote or rewrites history.
  @git_subcommands ~w(status log diff show add commit stash)

  # Flags the Git tool refuses, per subcommand, with the reason. They would
  # rewrite history, skip the repo's safeguards, write files outside git's
  # control, run external programs, or wait for an editor or terminal the
  # harness doesn't have (which would hang the session).
  @git_blocked_flags %{
    "commit" => [
      {"--amend", "rewrites the last commit"},
      {"--no-verify", "skips the repo's commit hooks"},
      {"-n", "skips the repo's commit hooks"},
      {"--interactive", "needs a terminal"},
      {"--patch", "needs a terminal"},
      {"-p", "needs a terminal"},
      {"--edit", "needs an editor"},
      {"-e", "needs an editor"}
    ],
    "add" => [
      {"--force", "adds files that .gitignore excludes, such as .env"},
      {"-f", "adds files that .gitignore excludes, such as .env"},
      {"--interactive", "needs a terminal"},
      {"-i", "needs a terminal"},
      {"--patch", "needs a terminal"},
      {"-p", "needs a terminal"},
      {"--edit", "needs an editor"},
      {"-e", "needs an editor"}
    ],
    "stash" => [
      {"--patch", "needs a terminal"},
      {"-p", "needs a terminal"}
    ],
    :all => [
      {"--output", "writes output to a file"},
      {"--ext-diff", "runs an external diff program"}
    ]
  }

  # `git stash <action>`: the ones that delete stashes (drop, clear) are
  # left out. No action means `push`.
  @git_stash_actions ~w(push list show pop apply)

  @tools [
    %{
      name: "Read",
      description:
        "Read a file from the local filesystem and return its contents " <>
          "(truncated to 50,000 characters; use Grep to find parts of larger files).",
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
      name: "Curl",
      description:
        "Run the native `curl` command with the given arguments and return its output " <>
          "(stdout and stderr, truncated to 50,000 characters) followed by the HTTP status. " <>
          "Use this instead of WebFetch when you need custom headers, cookies, methods or a " <>
          "request body. Pass each argument as its own array element exactly as the shell " <>
          "would after removing quotes and line continuations, e.g. " <>
          ~s|["https://example.com", "-H", "accept: text/html", "-b", "a=1; b=2"]. | <>
          "No shell is involved, so pipes, redirects and variables do not work: to search a " <>
          "large response, save it with -o <file> and then use Grep on that file.",
      input_schema: %{
        type: "object",
        properties: %{
          args: %{
            type: "array",
            items: %{type: "string"},
            description: "Arguments passed to curl (do not include the word curl itself)"
          }
        },
        required: ["args"],
        additionalProperties: false
      },
      strict: true
    },
    %{
      name: "Grep",
      description:
        "Search a file, or every file under a directory, for a regular expression " <>
          "(PCRE syntax, matched line by line) and return matches as file:line:text. " <>
          "Like `grep -n`; set only_matching to return just the matched text (`grep -o`). " <>
          "Use it to pull specific pieces out of large files, such as a page saved with Curl -o. " <>
          "Directory searches skip _build, deps and node_modules; pass one as the path to search it.",
      input_schema: %{
        type: "object",
        properties: %{
          pattern: %{type: "string", description: "Regular expression, e.g. <h[12][^>]*>[^<]*"},
          path: %{type: "string", description: "File or directory to search"},
          only_matching: %{
            type: "boolean",
            description: "Return only the matched text, not the whole line (default false)"
          },
          case_insensitive: %{type: "boolean", description: "Ignore case (default false)"},
          max_results: %{
            type: "integer",
            description: "Stop after this many results (default 100)"
          }
        },
        required: ["pattern", "path"],
        additionalProperties: false
      },
      strict: true
    },
    %{
      name: "Mix",
      description:
        "Run one allowlisted mix task in the project directory and return its output " <>
          "(stdout and stderr, truncated to 50,000 characters) followed by the exit code. " <>
          "A non-zero exit is reported as an error. Allowed tasks: " <>
          Enum.join(@mix_tasks, ", ") <> ".",
      input_schema: %{
        type: "object",
        properties: %{
          task: %{
            type: "string",
            enum: @mix_tasks,
            description: "The mix task to run, e.g. compile or test"
          }
        },
        required: ["task"],
        additionalProperties: false
      },
      strict: true
    },
    %{
      name: "Git",
      description:
        "Run one git subcommand in the working directory and return its output " <>
          "(stdout and stderr, truncated to 50,000 characters) followed by the exit code. " <>
          "Allowed subcommands: " <>
          Enum.join(@git_subcommands, ", ") <>
          ". Search history with log, e.g. args [\"--oneline\", \"--grep=cache\"] for " <>
          "commit messages, [\"-S\", \"text\"] for commits that added or removed text, or " <>
          "[\"-G\", \"regex\"]; then show <sha> to see one. Commit with args " <>
          "[\"-m\", \"message\"]; there is no editor. stash allows push, list, show, pop and " <>
          "apply. Refused: commit --amend and --no-verify, add --force, stash drop and " <>
          "clear, interactive or editor flags, --output and --ext-diff.",
      input_schema: %{
        type: "object",
        properties: %{
          subcommand: %{type: "string", enum: @git_subcommands},
          args: %{
            type: "array",
            items: %{type: "string"},
            description: "Arguments after the subcommand, one per element (may be empty)"
          }
        },
        required: ["subcommand", "args"],
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

  # Grep skips these when it walks a directory: build output and vendored
  # dependencies are large and rarely what you're looking for.
  @grep_skip_dirs ~w(_build deps node_modules)

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
  The text depends only on `cwd`, so it is byte-identical for every request in
  a session, which keeps it cacheable (see `request_body/2`).
  """
  def system_prompt(cwd) do
    """
    You are a coding agent running inside "go", a small custom harness written in
    Elixir. It is not Claude Code. Your only tools are
    #{Enum.map_join(@tools, ", ", & &1.name)};
    the harness runs them on the user's machine with the user's permissions.

    Working directory: #{cwd}
    Relative paths resolve against it; prefer them.

    There is no shell tool. You cannot pipe, redirect, chain commands or run
    arbitrary programs. To search a large web response, save it with Curl -o <file>
    and Grep that file instead of reading it whole.

    After changing Elixir code, run Mix compile and Mix test to verify it rather
    than assuming it works. Use Git freely to inspect and search history, but only
    add, commit or stash when the user asks; check Git status and diff first.

    If a tool you would need does not exist, say so instead of guessing. Changes
    to this harness's own code take effect only in the next session.

    Keep replies short and plain; the user reads them in a terminal.
    """
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

  def execute_tool("Curl", %{"args" => args}) when is_list(args) do
    # Args go straight to the curl binary (no shell), so nothing the model
    # passes can be interpreted as a pipe, redirect or second command.
    # Our defaults come first so the model's own flags win if repeated;
    # --write-out is last so the status line is always ours.
    {out, exit_code} =
      System.cmd(
        "curl",
        ["--silent", "--show-error", "--max-time", "60"] ++
          args ++ ["--write-out", "\n[curl] HTTP %{http_code}"],
        stderr_to_stdout: true
      )

    # Peel off the trailing status line we appended (anchored to the end, so
    # a response body that happens to contain "[curl] HTTP" can't fool it).
    {body, status_line} =
      case Regex.run(~r/\A(.*)\n\[curl\] (HTTP \d{3})\z/s, out) do
        [_, body, status] -> {body, status}
        nil -> {out, "HTTP ???"}
      end

    output = truncate(body) <> "\n\n" <> status_line <> " (exit #{exit_code})"
    {output, exit_code != 0}
  end

  def execute_tool("Grep", %{"pattern" => pattern, "path" => path} = input) do
    regex = Regex.compile!(pattern, if(input["case_insensitive"], do: "iu", else: "u"))
    only_matching? = input["only_matching"] == true
    max = input["max_results"] || 100

    files =
      cond do
        File.regular?(path) -> [path]
        File.dir?(path) -> files_under(path)
        true -> raise "No such file or directory: #{path}"
      end

    # Lazily walk file -> line -> match so we stop reading once we hit max.
    results =
      files
      |> Stream.flat_map(fn file ->
        text = File.read!(file)
        # Skip binaries (invalid UTF-8 would also make the "u" regex raise).
        if String.valid?(text), do: grep_lines(file, text, regex, only_matching?), else: []
      end)
      |> Enum.take(max + 1)

    output =
      case results do
        [] -> "No matches"
        _ -> Enum.take(results, max) |> Enum.join("\n") |> truncate()
      end

    note = if length(results) > max, do: "\n\n(stopped at max_results=#{max})", else: ""
    {output <> note, false}
  end

  def execute_tool("Mix", %{"task" => task}) when task not in @mix_tasks do
    allowed = Enum.join(@mix_tasks, ", ")
    {"Mix task not allowed: #{inspect(task)} (allowed: #{allowed})", true}
  end

  def execute_tool("Mix", %{"task" => task}) do
    # Task name goes straight to the mix binary as one argv element (no shell).
    {out, exit_code} = System.cmd("mix", [task], stderr_to_stdout: true)
    output = truncate(out) <> "\n\n(exit #{exit_code})"
    {output, exit_code != 0}
  end

  def execute_tool("Git", %{"subcommand" => subcommand, "args" => args}) when is_list(args) do
    case git_refusal(subcommand, args) do
      nil ->
        # No shell, and the subcommand is always the first argument, so the
        # model can't add git's global options (-c, --git-dir) in front of it.
        # GIT_EDITOR=true makes anything that would open an editor carry on
        # (or fail) instead of waiting forever; the pager is turned off too.
        {out, exit_code} =
          System.cmd("git", [subcommand | args],
            stderr_to_stdout: true,
            env: [{"GIT_EDITOR", "true"}, {"GIT_PAGER", "cat"}, {"GIT_TERMINAL_PROMPT", "0"}]
          )

        {truncate(out) <> "\n\n(exit #{exit_code})", exit_code != 0}

      reason ->
        {"Git refused: #{reason}", true}
    end
  end

  def execute_tool(name, _input), do: {"Unknown tool: #{name}", true}

  @doc """
  Why the Git tool won't run `git <subcommand> <args>`, or `nil` if it will.

  Checks the subcommand against `@git_subcommands`, `git stash`'s action
  against `@git_stash_actions`, and every flag against `@git_blocked_flags`.
  Bundled short flags count separately (`-fA` contains `-f`), a long flag
  matches with or without `=value`, and nothing after `--` is checked,
  because git treats it as a path.
  """
  def git_refusal(subcommand, _args) when subcommand not in @git_subcommands,
    do:
      "subcommand #{inspect(subcommand)} is not allowed (allowed: #{Enum.join(@git_subcommands, ", ")})"

  def git_refusal("stash", [action | _]) when action not in @git_stash_actions,
    do:
      if(String.starts_with?(action, "-"),
        do: git_refused_flag("stash", ["push", action]),
        else:
          "git stash #{action} is not allowed (allowed: #{Enum.join(@git_stash_actions, ", ")})"
      )

  def git_refusal(subcommand, args), do: git_refused_flag(subcommand, args)

  defp git_refused_flag(subcommand, args) do
    blocked = Map.get(@git_blocked_flags, subcommand, []) ++ @git_blocked_flags[:all]
    flags = args |> Enum.take_while(&(&1 != "--")) |> Enum.flat_map(&flag_names/1)

    Enum.find_value(blocked, fn {flag, reason} ->
      if flag in flags, do: "git #{subcommand} #{flag} is not allowed: it #{reason}"
    end)
  end

  # The flag names in one argument: "--output=x" -> ["--output"],
  # "-fA" -> ["-f", "-A"], anything that isn't a flag -> [].
  defp flag_names("--" <> _ = arg), do: [arg |> String.split("=", parts: 2) |> hd()]

  defp flag_names("-" <> letters) do
    if letters =~ ~r/\A[a-zA-Z]+\z/, do: for(<<c <- letters>>, do: "-" <> <<c>>), else: []
  end

  defp flag_names(_), do: []

  # Emits "file:line:text" per matching line, or one entry per match with -o.
  defp grep_lines(file, text, regex, only_matching?) do
    text
    |> String.split("\n")
    |> Stream.with_index(1)
    |> Stream.flat_map(fn {line, n} ->
      cond do
        only_matching? -> for [m | _] <- Regex.scan(regex, line), do: "#{file}:#{n}:#{m}"
        Regex.match?(regex, line) -> ["#{file}:#{n}:#{String.slice(line, 0, 500)}"]
        true -> []
      end
    end)
  end

  # Every regular file under dir, skipping @grep_skip_dirs (and, because
  # Path.wildcard ignores dotfiles, .git and other hidden folders).
  defp files_under(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.reject(fn file ->
      file |> Path.relative_to(dir) |> Path.split() |> Enum.any?(&(&1 in @grep_skip_dirs))
    end)
    |> Enum.filter(&File.regular?/1)
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
        "use Grep to find the part you need)"
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
