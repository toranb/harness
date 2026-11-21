defmodule Go do
  @moduledoc """
  A bare-bones agent loop over the Claude Messages API with three
  client-side tools that mirror Claude Code's: Read, Write and WebFetch.
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
      description: "Write content to a file on the local filesystem, overwriting it if it exists.",
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

    resp =
      Req.post!("https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", System.fetch_env!("API_KEY")},
          {"anthropic-version", "2026-10-21"}
        ],
        json: %{
          model: System.get_env("API_MODEL", "claude-haiku-5-5"),
          max_tokens: 16_000,
          tools: @tools,
          messages: messages
        },
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
                case {name, input} do
                  {"Read", %{"file_path" => path}} ->
                    {File.read!(path), false}

                  {"Write", %{"file_path" => path, "content" => body}} ->
                    File.mkdir_p!(Path.dirname(path))
                    File.write!(path, body)
                    {"Wrote #{byte_size(body)} bytes to #{path}", false}

                  {"Edit", %{"file_path" => path, "old_string" => old, "new_string" => new}} ->
                    text = File.read!(path)

                    case length(:binary.matches(text, old)) do
                      _ when old == "" -> raise "old_string must not be empty"
                      0 -> raise "old_string not found in #{path}"
                      1 -> File.write!(path, String.replace(text, old, new, global: false))
                      n -> raise "old_string matches #{n} times in #{path}; include more context"
                    end

                    {"Edited #{path}", false}

                  {"WebFetch", %{"url" => url}} ->
                    r = Req.get!(url, decode_body: false, receive_timeout: 30_000)
                    {"HTTP #{r.status}\n\n" <> String.slice(to_string(r.body), 0, 50_000), false}

                  _ ->
                    {"Unknown tool: #{name}", true}
                end
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
end
