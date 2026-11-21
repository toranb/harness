defmodule Go do
  @moduledoc """
  A bare-bones agent loop over the Claude Messages API with three
  client-side tools that mirror Claude Code's: Read, Write, Edit, WebFetch,
  plus Curl, which shells out to the native `curl` binary.
  """

  @tools [
    %{
      name: "Read",
      description: "Read a file from the local filesystem and return its contents.",
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
          "No shell is involved, so pipes, redirects and variables do not work.",
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
    }
  ]

  @doc """
  Interactive agent session. Starts from a prompt, runs tools until the
  model finishes its turn, then waits at a `>` prompt for the next message.
  The conversation keeps its history across prompts.
  Type `exit` or press Ctrl-D to quit.
  """
  def run(prompt) when is_binary(prompt), do: run([%{role: "user", content: prompt}])

  def run(messages) when is_list(messages) do
    {:ok, _} = Application.ensure_all_started(:req)

    body = %{
      model: System.get_env("API_MODEL", "claude-haiku-5-5"),
      max_tokens: 16_000,
      tools: @tools,
      messages: messages
    }

    # --debug: dump the full request body (the whole context) on every call.
    if Application.get_env(:go, :debug, false) do
      IO.inspect(body,
        label: "\n[debug] POST /v1/messages (#{length(messages)} messages)",
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity
      )
    end

    resp =
      Req.post!("https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", System.fetch_env!("API_KEY")},
          {"anthropic-version", "2026-10-21"}
        ],
        json: body,
        receive_timeout: 600_000
      )

    if resp.status != 200, do: raise("API error #{resp.status}: #{inspect(resp.body)}")

    %{"content" => content, "stop_reason" => stop_reason} = resp.body

    for %{"type" => "text", "text" => text} <- content, do: IO.puts(text)

    # Append the full content (thinking blocks included) unchanged.
    messages = messages ++ [%{role: "assistant", content: content}]

    case stop_reason do
      "tool_use" ->
        results =
          for %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} <- content do
            IO.puts("-> #{name} #{inspect(input)}")

            {output, error?} =
              try do
                execute_tool(name, input)
              rescue
                e -> {Exception.message(e), true}
              end

            %{type: "tool_result", tool_use_id: id, content: output, is_error: error?}
          end

        run(messages ++ [%{role: "user", content: results}])

      "end_turn" ->
        # Turn is done: wait for the next prompt (skipping blank lines).
        input =
          Stream.repeatedly(fn -> IO.gets("\n> ") end)
          |> Enum.find(&(not is_binary(&1) or String.trim(&1) != ""))

        if is_binary(input) and String.trim(input) not in ["exit", "quit"],
          do: run(messages ++ [%{role: "user", content: String.trim(input)}]),
          else: :ok

      other ->
        raise "Agent stopped with stop_reason=#{other}"
    end
  end

  @doc false
  # Runs one tool call. Returns {output, is_error}.
  def execute_tool("Read", %{"file_path" => path}), do: {File.read!(path), false}

  def execute_tool("Write", %{"file_path" => path, "content" => body}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    {"Wrote #{byte_size(body)} bytes to #{path}", false}
  end

  def execute_tool("Edit", %{"file_path" => path, "old_string" => old, "new_string" => new}) do
    text = File.read!(path)

    case length(:binary.matches(text, old)) do
      _ when old == "" -> raise "old_string must not be empty"
      0 -> raise "old_string not found in #{path}"
      1 -> File.write!(path, String.replace(text, old, new, global: false))
      n -> raise "old_string matches #{n} times in #{path}; include more context"
    end

    {"Edited #{path}", false}
  end

  def execute_tool("WebFetch", %{"url" => url}) do
    r = Req.get!(url, decode_body: false, receive_timeout: 30_000)
    {"HTTP #{r.status}\n\n" <> String.slice(to_string(r.body), 0, 50_000), false}
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

    output = String.slice(body, 0, 50_000) <> "\n\n" <> status_line <> " (exit #{exit_code})"
    {output, exit_code != 0}
  end

  def execute_tool(name, _input), do: {"Unknown tool: #{name}", true}
end
