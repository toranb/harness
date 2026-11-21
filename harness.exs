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
  plus Curl, which shells out to the native `curl` binary.
  """

  # The only mix tasks the Mix tool will run.
  @mix_tasks ~w(deps.get compile test format)

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
    }
  ]

  # Every tool result is cut to this many characters, so one big file or web
  # page can't flood the context window. truncate/1 adds a note when it cuts.
  @max_output 50_000

  # Grep skips these when it walks a directory: build output and vendored
  # dependencies are large and rarely what you're looking for.
  @grep_skip_dirs ~w(_build deps node_modules)

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
    Elixir. It is not Claude Code. Your only tools are #{Enum.map_join(@tools, ", ", & &1.name)};
    the harness runs them on the user's machine with the user's permissions.

    Working directory: #{cwd}
    Relative paths resolve against it; prefer them.

    There is no shell tool. You cannot pipe, redirect, chain commands or run
    arbitrary programs. To search a large web response, save it with Curl -o <file>
    and Grep that file instead of reading it whole.

    After changing Elixir code, run Mix compile and Mix test to verify it rather
    than assuming it works. If a tool you would need does not exist, say so instead
    of guessing. Changes to this harness's own code take effect only in the next
    session.

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
      max_tokens: 16_000,
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

    1. send the conversation to the model (`call_model/1`)
    2. if the model asked for tools, run them (`run_tools/1`), append the
       results to the conversation and go back to 1
    3. otherwise its turn is over: read the user's next message
       (`read_user_input/0`), append it and go back to 1

  The conversation (`messages`) only ever grows, and every request sends all
  of it. A blank prompt asks for one at `>`. Type `exit` or press Ctrl-D to quit.
  """
  def run(prompt) when is_binary(prompt) do
    {:ok, _} = Application.ensure_all_started(:req)

    case String.trim(prompt) do
      "" ->
        with {:ok, prompt} <- read_user_input(), do: run(prompt)

      prompt ->
        loop([%{role: "user", content: first_message(prompt, File.cwd!())}], 1)
    end
  end

  # One pass = one request to the model. `turn` counts requests, for display.
  defp loop(messages, turn) do
    case call_model(messages) do
      {:ok, response} ->
        print_response(response, turn)
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

  # The model finished its turn: wait for the user's next message.
  defp next_prompt(messages, turn) do
    case read_user_input() do
      {:ok, text} -> loop(messages ++ [%{role: "user", content: text}], turn)
      :exit -> :ok
    end
  end

  @doc """
  Sends the conversation to the Messages API.

  Returns `{:ok, response_body}` or `{:error, reason}`. Errors are returned
  rather than raised, so a failed request doesn't end the session.
  With `--debug`, prints the full request body first.
  """
  def call_model(messages) do
    body = request_body(messages, File.cwd!())

    if Application.get_env(:go, :debug, false) do
      IO.inspect(body,
        label: "\n[debug] POST /v1/messages (#{length(messages)} messages)",
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity
      )
    end

    result =
      Req.post("https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", System.fetch_env!("API_KEY")},
          {"anthropic-version", "2026-10-21"}
        ],
        json: body,
        receive_timeout: 600_000
      )

    case result do
      {:ok, %{status: 200, body: response}} -> {:ok, response}
      {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{inspect(body)}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  # Prints the model's text, then one status line so you can watch the loop.
  defp print_response(%{"content" => content} = response, turn) do
    for %{"type" => "text", "text" => text} <- content, do: IO.puts(text)
    IO.puts(turn_status(turn, response["stop_reason"], response["usage"]))
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

    "[turn #{turn}] stop_reason=#{stop_reason} | prompt #{read + written + uncached} tokens " <>
      "(cache read #{read}, cache write #{written}, uncached #{uncached}) | " <>
      "output #{usage["output_tokens"] || 0} tokens"
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
  Reads the user's next message at the `>` prompt, skipping blank lines.
  Returns `{:ok, text}`, or `:exit` for `exit`, `quit` or Ctrl-D.
  """
  def read_user_input do
    case read_line("\n> ") do
      :eof -> :exit
      "" -> read_user_input()
      text when text in ["exit", "quit"] -> :exit
      text -> {:ok, text}
    end
  end

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

  def execute_tool(name, _input), do: {"Unknown tool: #{name}", true}

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
