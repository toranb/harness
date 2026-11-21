# go

A small coding agent in one Elixir file, written to learn how a model and a
harness work together. `harness.exs` sends your prompt to Claude, runs the
tools the model asks for on your machine, sends the results back, and repeats
until the model has an answer. The loop is a handful of short functions, and
it prints every step as it runs.

It is built to get things done fast, with no brakes. The model has a real
bash shell and your permissions, and nothing asks you before a tool runs.
See [Safety](#safety).

```zsh
source .env                               # API_KEY=..., optional API_MODEL=...
elixir harness.exs "Find the line defining @max_output in harness.exs and tell me its value in one line."
```

```text
[turn 1] stop_reason=tool_use | prompt 1656 tokens (cache read 0, cache write 1652, uncached 4) | output 69 tokens
-> Bash %{"command" => "grep -rn \"@max_output\" --include=*.exs . | head -20"}
<- ok, 440 chars: ./harness.exs:117:  @max_output 50_000
`@max_output` is set to `50_000` (line 117 of harness.exs).
[turn 2] stop_reason=end_turn | prompt 1916 tokens (cache read 1652, cache write 262, uncached 2) | output 28 tokens

>
```

This one prompt took two requests. In the first, the model asked for a tool
(`stop_reason=tool_use`): a `grep | head` pipeline in Bash. The harness ran
it and sent back the output. In the second, the model answered without
asking for a tool, which ended its turn (`end_turn`). The harness is now
waiting at `>` for your next message.

## Contents

- [Map of harness.exs](#map-of-harnessexs)
- [Glossary](#glossary)
- [Running it](#running-it)
- [Features](#features)
- [From prompt to reply](#from-prompt-to-reply)
- [How the agent decides to stop](#how-the-agent-decides-to-stop)
- [What the model sees](#what-the-model-sees)
- [Tools](#tools)
- [How to add a tool](#how-to-add-a-tool)
- [Reading the output](#reading-the-output)
- [Streaming](#streaming)
- [Prompt caching](#prompt-caching)
- [Compaction (/compact)](#compaction-compact)
- [Safety](#safety)
- [Tests](#tests)
- [Limitations](#limitations)

## Map of harness.exs

`harness.exs` is one module, `Go`, of about 1,000 lines. It has six parts.
Each part teaches one idea, and you can read them in any order. Banner
comments (`# ---- The agent loop ----`) mark the loop, compaction, streaming
and tools sections in the file. The request part has no banner; look for
the function names below.

| Part | Functions | What it teaches | Where in the file | Read more |
|---|---|---|---|---|
| **1. The loop** | `run/1`, `start/1`, `loop/2`, `next_prompt/2`, `add_user_text/2`, `run_tools/1` | An agent is a loop. Send the conversation, run any tools the model asked for, append the results, and repeat until the model stops asking. Then wait for the user. | "The agent loop" banner; `run_tools/1` sits after the streaming section | [From prompt to reply](#from-prompt-to-reply), [How the agent decides to stop](#how-the-agent-decides-to-stop) |
| **2. The request** | `system_prompt/2`, `machine/0`, `first_message/2`, `request_body/2`, `call_model/2` | What one API call contains: model, `max_tokens`, a system prompt that states the facts about the machine, tool schemas, the whole conversation, and the two cache breakpoints. The model remembers nothing between calls. | Just above the loop banner; `call_model/2` just after compaction | [What the model sees](#what-the-model-sees), [Prompt caching](#prompt-caching) |
| **3. Streaming** | `new_stream/0`, `consume_chunk/2`, `apply_event/2`, `finish_stream/1` | Rebuilding a complete response from server-sent events, so text prints while it's written and the rest of the loop never knows it was streamed | "Streaming" banner | [Streaming](#streaming) |
| **4. Compaction** | `compact/3`, `compaction_prompt/1`, `extract_summary/1`, `compacted_messages/2` | Context is finite. `/compact` swaps the whole conversation for a summary that the model writes. | "Compaction" banner | [Compaction](#compaction-compact) |
| **5. Tools** | `@tools`, `execute_tool/2` | A tool has two halves: a JSON schema that tells the model what it may ask for, and an Elixir clause that does the work and returns `{output, is_error}` | `@tools` near the top; `execute_tool/2` under the "Tools" banner | [Tools](#tools), [How to add a tool](#how-to-add-a-tool) |
| **6. The Bash tool** | `@bash_env`, `run_bash/2`, `collect_output/3`, `kill_port/1` | Running a real shell without letting it hang the session: empty stdin, no editor or pager, a deadline, and a kill | Attributes above `system_prompt/2`; functions after `execute_tool/2` | [The Bash tool](#the-bash-tool) |

Supporting pieces:

| Piece | What it is |
|---|---|
| `Mix.install([{:req, "0.7.5"}])` | The only dependency, pinned so every install is the same |
| `@max_tokens`, `@max_output`, `@compact_hint_tokens` | Limits: 128,000 output tokens per reply, 50,000 characters per tool result, and the prompt size at which the status line suggests `/compact` |
| `@bash_timeout`, `@bash_max_timeout`, `@bash_max_bytes` | Bash's default timeout (120 s), its upper limit (600 s), and the most output it keeps in memory while a command runs (1 MB) |
| `@known_programs` | The programs the system prompt reports as installed, if they are |
| `turn_status/3`, `result_summary/2` | The status line and the `->` / `<-` lines you see in the terminal |
| `@commands`, `help_text/0`, `read_user_input/0`, `parse_input/1` | The `>` prompt: messages, `/help`, `/compact`, and `exit` |
| `truncate/1` | Cuts any tool result to 50,000 characters and says so |
| Entry point (bottom of file) | Parses `--debug` and calls `Go.run/1`. It doesn't run when the tests load the file |

## Glossary

- **Context window**: the most tokens the model can take in one request:
  tools, system prompt and the whole conversation together. Every request
  resends the whole conversation, so a session gets closer to this limit
  with every turn.
- **Compaction**: replacing the conversation with a shorter summary so a
  session fits in the context window again. Here it runs only when you type
  `/compact`.
- **`stop_reason`**: a field on every API response that says why the model
  stopped: `tool_use`, `end_turn`, `max_tokens` and so on. The loop looks at
  this field and nothing else to decide what to do next.
- **`tool_use` / `tool_result`**: the two halves of a tool call. In its
  reply the model sends a `tool_use` block with a tool name, an input and an
  id. The harness runs the tool and sends back a `tool_result` block in the
  next user message, with the same id (`tool_use_id`), the output and
  `is_error`.
- **`cache_control`**: a marker in the request (a cache breakpoint) that
  asks the API to cache everything up to that point. The next request can
  then read that prefix from cache, which is faster and costs less than
  processing it again.
- **SSE (server-sent events)**: the streaming format. The HTTP response
  stays open, and the API sends small `event:`/`data:` records, separated by
  blank lines, while the model writes.
- **Turn**: in the status line, one request to the model. One message from
  you can take many turns.

## Running it

You need Elixir and Erlang (versions in `.tool-versions`), bash, and an
Anthropic API key, on Linux or macOS. Req, the HTTP client, is the only
dependency. `Mix.install` downloads it on the first run and caches it after
that. There is no mix project to set up. Whatever else the agent uses (git,
curl, mix, rg and so on) is whatever your machine already has.

Put your settings in `.env`, which git ignores:

```zsh
export API_KEY=sk-ant-...
export API_MODEL=claude-haiku-5-5   # optional; this is the default
```

Then:

```zsh
source .env
elixir harness.exs                        # asks for a prompt at >
elixir harness.exs "your prompt here"     # starts with this prompt
elixir harness.exs --debug "your prompt"  # also prints every full request
elixir harness_test.exs                   # unit tests (no API calls)
```

The agent works in the directory you run it from. To use it on another
project, `cd` there and run `elixir /path/to/harness.exs`.

At the `>` prompt you can keep talking: each message continues the same
conversation. A few inputs are commands instead of messages:

```text
Commands:
  /help               list these commands
  /compact [focus]    summarize the conversation to free up context (optional focus)
  exit, quit, Ctrl-D  end the session
Anything else you type is sent to the model.
```

That is the output of `/help`, which also works before your first message.
An unknown command such as `/foo` says so and points you to `/help`. Only a
slash followed by letters counts as a command, so a message starting with a
path like `/home/me/app` still goes to the model. See
[Compaction](#compaction-compact) for what `/compact` does. The conversation
is not saved after you exit.

## Features

- **A visible agent loop.** After every response it prints the turn number,
  why the model stopped, and how many tokens the conversation now uses. Every
  tool call prints its input and a one-line summary of its result.
- **Five tools:** Read, Write, Edit, WebFetch and Bash ([details](#tools)).
  Bash is a real shell, so the model can use git, curl, grep, mix and
  anything else installed, with pipes and all.
- **No guessing about the machine.** The system prompt states the OS, the
  bash version and which common programs are installed, so the model writes
  commands that work here (BSD `sed` on macOS, GNU on Linux).
- **No prompts, no allowlists.** Every tool call runs right away.
- **AGENTS.md support.** If the working directory has an `AGENTS.md`, it is
  put in front of your first message, so the project's rules apply for the
  whole session.
- **Streaming.** Replies appear word by word as the model writes them,
  instead of all at once at the end ([details](#streaming)).
- **Manual compaction.** `/compact` replaces a long conversation with a
  summary so the session can keep going. It only happens when you type it
  ([details](#compaction-compact)).
- **Prompt caching** on every request. The tools, the system prompt and the
  conversation so far are read from cache instead of being processed again.
- **Errors don't end the session.** If a tool fails, the model gets the error
  message and can try again. If an API request fails, you see the error, the
  conversation is kept, and Enter retries the request.
- **Output limits.** Every tool result is cut at 50,000 characters, with a
  note saying so, so one large file or web page can't fill the context.
- **`--debug`** prints the complete JSON of every request, so you can see
  exactly what the model receives.
- **One file.** `harness.exs` is the whole program. `harness_test.exs` holds
  its tests.

## From prompt to reply

```text
  you type a prompt
        │
        ▼
  messages = [user: AGENTS.md (if any) + your prompt]
        │
        ▼
 ┌─► call_model(messages) ── POST /v1/messages (streamed) with tools + system + all messages
 │      │
 │      ▼
 │   append the assistant's reply to messages
 │      │
 │      ▼
 │   stop_reason == "tool_use"?
 │      │yes                                  │no
 │      ▼                                     ▼
 │   run_tools: run each tool call,        print the reply, wait at >
 │   append the results as one            (exit / quit / Ctrl-D ends it)
 │   user message                               │
 │      │                                       │ you type the next message
 └──────┴───────────────────────────────────────┘ (appended to messages)
```

Step by step, using the function names in `harness.exs`:

1. **`run/1`** takes your prompt. If it is blank, it asks for one at `>`.
   It builds the first user message with **`first_message/2`**, which adds
   `AGENTS.md` if there is one, and starts the loop.
2. **`loop/2`** runs once per request to the model. It calls
   **`call_model/2`**, which uses **`request_body/2`** to build the request.
   That is the model name, `max_tokens`, the system prompt, the five tool
   definitions, and the *entire* conversation so far. The model has no memory
   between requests; the conversation in `messages` is its only memory, and
   every request sends all of it.
3. The response is a list of content blocks. **Text** blocks are what the
   model says to you. **`tool_use`** blocks are requests to run a tool, each
   with a tool name, an input that matches that tool's schema, and an id.
   **Thinking** blocks are the model's own reasoning. The reply is streamed,
   so the text is printed as it is generated, and the harness rebuilds the
   complete list of blocks from the stream ([Streaming](#streaming)). It
   adds the whole reply, unchanged, to `messages`.
4. If the model asked for tools, **`run_tools/1`** runs each `tool_use`
   block in order through **`execute_tool/2`**. It collects one
   `tool_result` per call, with the same id and an `is_error` flag. All the
   results go back as a single user message, and the loop sends the
   conversation again. The model then reads the results and either asks for
   more tools or answers.
5. When the model stops asking for tools, its turn is over.
   **`next_prompt/2`** waits at `>` (**`read_user_input/0`**). A message is
   added to `messages` and the loop continues; `/compact` replaces
   `messages` with a summary first ([below](#compaction-compact)).

A single prompt can lead to many requests. "Fix the failing test" might be
Read, Edit, `mix test`, Edit, `mix test`, then a final answer: six requests
in one turn, each a little bigger than the last.

## How the agent decides to stop

**The model decides, not the harness.** The harness never looks at what the
model wrote to judge whether the task is done. It only reads the
`stop_reason` field that the API returns with every response:

| `stop_reason` | What it means | What the harness does |
|---|---|---|
| `tool_use` | The model asked for one or more tools and is waiting for the results | Run them, send the results, call the model again |
| `end_turn` | The model finished its answer | Wait for your next message at `>` |
| `max_tokens` | The reply hit the 128,000-token output limit | Treat it as the end of the turn (see [Limitations](#limitations)) |
| anything else (e.g. `refusal`) | The model stopped for another reason | Treat it as the end of the turn |

The whole decision is one line in `loop/2`:

```elixir
if response["stop_reason"] == "tool_use" do
```

So the model keeps working for as long as it keeps calling tools. When it
thinks it has what it needs, it writes a reply without a tool call, the API
reports `end_turn`, and control comes back to you. Nothing in the harness
limits the number of tool calls in a turn. The model's own judgement and the
system prompt's guidance (verify changes with `mix test`, say so if a
program is missing) shape when it stops.

The *session* ends only when you say so: `exit`, `quit`, Ctrl-D, or `exit` at
the retry prompt after an API error.

## What the model sees

Every request has the same four parts, in this order:

1. **Tools**: the five tool definitions in `@tools`. Each has a name, a
   description that tells the model when and how to use it, and a JSON input
   schema. `strict: true` makes the API guarantee that tool inputs match the
   schema.
2. **System prompt** (`system_prompt/2`): what this harness is, the tool
   names (built from `@tools` so the two can't drift), that nothing asks
   before a tool runs, and the working directory. Then the facts about the
   machine, which `machine/0` detects once per session:

   ```text
   Machine: Linux 6.8.0, bash 5.1.16. Installed: git, curl, grep, sed, awk, find,
   jq, make, mix, elixir, erl, node, npm, python3, docker.
   ```

   On macOS that line also says the tools are the BSD versions (`sed -i`
   needs an argument, `grep` has no `-P`) and that there is no `timeout`
   command. The prompt then explains how Bash runs commands (a fresh shell
   each time, empty stdin, no editor or pager) and says to use Read, Edit and
   Write for files, to verify Elixir changes with `mix compile` and
   `mix test`, to say so when a program is missing, and to keep replies
   short.
3. **First user message** (`first_message/2`): the contents of `AGENTS.md`
   wrapped in `<project_instructions>`, if the file exists, followed by your
   prompt.
4. **The rest of the conversation**: every reply, tool call, tool result and
   message since then, in order.

The request goes to `POST https://api.anthropic.com/v1/messages` with your
`API_KEY` in the `x-api-key` header, an `anthropic-version` header, and
`stream: true` (see [Streaming](#streaming)). The harness waits up to 10
minutes for a reply.

Run with `--debug` to see the full request for every turn.

## Tools

| Tool | What it does | Limits |
|---|---|---|
| **Read** | Returns a file's contents | Cut at 50,000 characters |
| **Write** | Creates or overwrites a file, creating folders as needed | |
| **Edit** | Replaces one exact occurrence of `old_string` with `new_string` | `old_string` must not be empty and must appear exactly once |
| **WebFetch** | Plain HTTP GET of a URL | 30-second timeout, body cut at 50,000 characters |
| **Bash** | Runs any command with `bash -c` in the working directory and returns stdout and stderr together, then the exit code | Killed after `timeout` seconds (default 120, max 600). Output cut at 50,000 characters |

Read, Write and Edit stay as separate tools even though Bash could do the
same jobs. An exact-match Edit is far more reliable than the model rewriting
files with `sed` or heredocs, and it fails loudly when the text isn't found.

### The Bash tool

Bash gives the model everything a shell has: pipes, redirects, `&&`, globs,
git (including `push`, `reset` and `rebase`), curl, mix, package managers.
Nothing is filtered. The only work the harness does is to make sure a
command can't hang the session, because there is no terminal for it to talk
to:

- **Stdin is empty.** The script starts with `exec </dev/null`, so a command
  that reads input (`cat`, a `[y/N]` prompt) gets end-of-file and moves on.
- **No editor, pager or password prompt.** `GIT_EDITOR`, `EDITOR` and
  `VISUAL` are set to `true`, `PAGER` and `GIT_PAGER` to `cat`, and
  `GIT_TERMINAL_PROMPT` to `0`. So `git commit` without `-m` fails instead of
  waiting for an editor, and `git log` prints instead of opening `less`.
- **A deadline.** `run_bash/2` runs bash in an Erlang Port instead of
  `System.cmd`, which has no timeout (and macOS has no `timeout` command).
  If the command is still running at the deadline, `kill_port/1` kills the
  shell and the processes it started, and the result ends with
  `(killed after N seconds)` and is an error. The model can pass a longer
  `timeout` for slow builds, or start a server in the background with `&`.
- **Bounded output.** At most 1 MB of output is kept while the command runs,
  so `yes` can't fill memory before the deadline. Bytes that aren't valid
  UTF-8 become `�`, because the result goes back to the API as JSON.

Each call is a fresh shell: `cd` and `export` don't carry over to the next
call, so the model chains them (`cd lib && ls`). A non-zero exit code is
reported as an error, which tells the model the command failed.

When a tool fails, for example because a file is missing, an Edit
`old_string` isn't found, or a command exits non-zero, the error goes back
to the model as a result with `is_error: true`. Models usually fix their call
and try again. When a clause raises, `run_tools/1` rescues the exception and
sends its message as an error result. A tool name with no clause gets
`Unknown tool: <name>` back from the catch-all `execute_tool/2` clause.

## How to add a tool

Adding a tool shows the core idea of this demo: **the model only ever sees a
schema, and the harness decides what actually runs.** Bash can already run
any program, so a new tool is worth adding when it does something the shell
can't, or does it more reliably. The example below adds `Ask`, which asks
you a question in the terminal. Bash can't do that, because its stdin is
empty.

It takes up to three edits to `harness.exs`:

**1. If the tool needs a limit, add it as a module attribute.** Put it next
to the `@bash_*` attributes, above `@tools`, so the schema in step 2 can use
it: a list of allowed values for an `enum`, a size, a timeout. `Ask` needs
none, so it skips this step. A tool that should only accept some values
would add, for example, `@npm_scripts ~w(test lint build)`, use it as the
`enum` in its schema, and check it again with a `when script in
@npm_scripts` guard on its clause.

**2. Add a schema to `@tools`.** The `name` is how the model calls the tool.
The `description` is how it decides *when* to call it, so say what the tool
returns and when not to use it. Under `strict: true`, the input must match
`input_schema`. `additionalProperties: false` is required with
`strict: true`.

```elixir
%{
  name: "Ask",
  description:
    "Ask the user a question in the terminal and return their answer. Use it when " <>
      "you need a decision or a fact only the user has; don't use it for things you " <>
      "can find out with your other tools.",
  input_schema: %{
    type: "object",
    properties: %{question: %{type: "string", description: "The question to ask"}},
    required: ["question"],
    additionalProperties: false
  },
  strict: true
}
```

**3. Add an `execute_tool/2` clause.** The first argument is the tool's name
and the second is its input, decoded from JSON with **string** keys. The
function returns `{output, is_error}`. Put the clause **above** the
catch-all `execute_tool(name, _input)`, or it will never match. The clause
runs inside the harness, so it can use anything in the `Go` module, here the
private `read_line/1` that the `>` prompt uses. Pass long output through
`truncate/1`.

```elixir
def execute_tool("Ask", %{"question" => question}) do
  IO.puts("\n[question] " <> question)

  case read_line("answer> ") do
    :eof -> {"The user did not answer.", true}
    answer -> {answer, false}
  end
end
```

Things you get without more work:

- The system prompt lists tool names from `@tools`, so the model learns that
  `Ask` exists.
- A failure, whether an error result or a raised exception, goes back to the
  model as an error result it can react to.
- The terminal prints the tool call (`-> Ask %{"question" => "..."}`) and a
  summary of its result.

Changing `@tools` changes the cached prefix, so the first request after the
change is a cache miss. Then add a test in `harness_test.exs` that calls
`Go.execute_tool("Ask", ...)` directly, as the Bash tests do (wrap it in
`capture_io/2` to supply the answer). Restart the harness to load the new
tool.

## Reading the output

```text
[turn 1] stop_reason=tool_use | prompt 1656 tokens (cache read 0, cache write 1652, uncached 4) | output 69 tokens
-> Bash %{"command" => "grep -rn \"@max_output\" --include=*.exs . | head -20"}
<- ok, 440 chars: ./harness.exs:117:  @max_output 50_000
```

- **`[turn N]`** counts requests to the model in this session, not your
  messages.
- **`stop_reason`** is what the loop acts on ([above](#how-the-agent-decides-to-stop)).
- **`prompt N tokens`** is the size of the whole request: cache read plus
  cache write plus uncached. Watching it grow turn by turn shows how an
  agent's context fills up.
- **`output N tokens`** is what the model generated: its text, tool calls
  and thinking.
- **`->`** is a tool call and its input (long strings are shortened on
  screen only).
- **`<-`** is the result: `ok` or `error`, its length, and the start of its
  first line. The model always receives the full result.

## Streaming

Every request sets `stream: true`. Instead of waiting for the whole reply and
receiving one JSON body, the harness gets the reply as
[server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
while the model is still writing it, and prints text as soon as it arrives.
In a test, one reply reached the terminal in 72 separate pieces over about
seven seconds.

A streamed reply is a sequence of small events, each a line of JSON:

```text
message_start         prompt token counts (input and cache)
content_block_start   index 0 is a thinking block
content_block_delta   index 0: signature_delta
content_block_stop    index 0 is complete
content_block_start   index 1 is a text block
content_block_delta   index 1: text_delta "Let me "     ← printed now
content_block_delta   index 1: text_delta "look."       ← printed now
content_block_stop    index 1 is complete               ← newline printed
content_block_start   index 2 is a tool_use block (Read)
content_block_delta   index 2: input_json_delta "{\"file_"
content_block_delta   index 2: input_json_delta "path\": \"a.ex\"}"
content_block_stop    index 2 is complete: decode the input JSON
message_delta         stop_reason "tool_use", output token count
message_stop
```

The harness rebuilds the same response the non-streaming API would have
returned, so nothing else in the loop changes:

- **`consume_chunk/2`** receives each piece of the HTTP body as Req reads it.
  A network chunk can end partway through an event, so it applies only the
  complete events (each ends with a blank line) and keeps the rest for the
  next chunk.
- **`apply_event/2`** updates the reply being built (**`new_stream/0`**).
  Text and thinking pieces are appended to their block. A tool call's input
  arrives as pieces of a JSON string and is decoded once its block ends.
  `ping` events and event types it doesn't recognize are ignored.
- **`finish_stream/1`** returns `{:ok, response}` with the blocks in index
  order, the `stop_reason` and the token counts. If the API sent an `error`
  event partway through, or the connection dropped before a `stop_reason`
  arrived, it returns an error instead, and the usual retry prompt appears.

Rebuilding the blocks exactly matters. Every block, including thinking blocks
and their signatures, goes back to the API on the next request, and the API
rejects a conversation whose earlier blocks were changed.

`/compact` streams its summary request too, but doesn't print it as it
arrives. It prints the finished summary once, between clear markers.

The API also offers `eager_input_streaming` for tools, which sends a tool
call's input before the API has checked it against the schema. The harness
leaves it off: it only runs tools once the whole reply has arrived, so there
is nothing to gain, and keeping it off keeps `strict: true`'s guarantee that
tool inputs match their schemas.

## Prompt caching

Every request repeats everything that came before it, so without caching the
API would process the same tokens again and again. `request_body/2` sets two
cache breakpoints:

1. **On the system prompt.** The API orders a request as tools, then system,
   then messages, so this breakpoint caches the tools and system prompt
   together. They are the same for every request and every session in the
   same folder on the same machine.
2. **Automatic, at the end of the conversation** (the top-level
   `cache_control`). The API places it on the last block and moves it as the
   conversation grows, so each request reads the previous request from cache
   and only pays full price for what is new.

In the example above, turn 2 read 1,652 tokens from cache and processed only
264 new ones. Cache entries last 5 minutes from their last use. Anything that
changes the cached bytes, such as a different tool list, system prompt or
model, causes a miss. That is why `machine/0` detects the machine only once
per session: if the agent installs `rg` partway through, the system prompt
doesn't change and the cache still hits.

## Compaction (/compact)

The conversation grows with every request, and every request sends all of
it, so a long session eventually gets slow, expensive, and close to the
model's context limit. `/compact` fixes that by replacing the conversation
with a summary of it.

```text
> /compact
> /compact keep the exact error messages     # optional: what to pay attention to
```

It only happens when you type the command. The status line suggests it once
a prompt passes 150,000 tokens (`large context: /compact to shrink it`), but
it never compacts on its own. You can only type it at `>`, between turns, so
it never interrupts a tool call that is waiting for its result.

What happens (`compact/3`):

1. The harness sends the whole conversation plus one more message asking for
   a summary (`compaction_prompt/1`). That prompt, suggested by Anthropic for
   this purpose, lists what the summary must keep: problems hit and how they
   were handled, decisions and constraints in your own words, where things
   stand, what is still open, and exact names, numbers and wording. Anything
   you type after `/compact` is added as extra focus. Because the
   conversation is already cached, this request is cheap.
2. It takes the text inside the reply's `<summary>` tags
   (`extract_summary/1`) and prints it, so you can see exactly what the model
   will remember.
3. It starts a new conversation that holds only `AGENTS.md` (if there is one)
   and the summary, marked as `<earlier_conversation_summary>`
   (`compacted_messages/2`). Your next message is appended to that same user
   message (`add_user_text/2`), not sent as a new one, because the API
   requires user and assistant messages to alternate.

Nothing from before the summary is replayed: no earlier messages, tool
results or thinking blocks. This is deliberate. Editing or trimming an old
conversation that contains thinking blocks can be rejected by the API, while
a fresh conversation that starts from a summary is always valid. The cost is
that **the summary is all the model knows** about the earlier session, so
read it, and if something important is missing, tell the model in your next
message.

In a test session, a conversation that had read the README went from an
8,194-token prompt to 3,049 tokens after `/compact`. The model still
answered questions about details from before the summary correctly. The
tools and system prompt stay cached across a compaction; the conversation
starts a new cache entry.

If the summary request fails, for example because of an API error, the
harness prints `[compact failed]` and the conversation is left unchanged.

## Safety

There isn't any, on purpose. This agent is all gas and no brakes.

- **Every tool call runs immediately, with your permissions.** Bash can run
  anything you can: `rm -rf`, `git push --force`, `git reset --hard`,
  `sudo` if it doesn't need a password, `curl ... | sh`. Write and Edit can
  change any file you can change, anywhere.
- **Nothing is filtered.** There is no allowlist, no denylist and no
  confirmation step. The only guidance is the system prompt, and the model
  can ignore it.
- **The network is open.** Bash, curl and WebFetch can send anything the
  model reads, including `.env`, to any URL.
- **AGENTS.md is followed as your instructions,** and so, in practice, is
  anything the model reads that tells it what to do: a web page, a README,
  a code comment. Only point it at projects and content you trust.
- **`--debug` prints everything,** including file contents and any tokens
  used in commands. Don't share that output.

If you want brakes, run it in a container or a throwaway VM, or with a
user account that can't reach anything you care about. Commit your work
before a session, so `git` can get it back.

## Tests

```zsh
elixir harness_test.exs
```

The tests load `harness.exs` without starting a session and check the
tools, the system prompt, AGENTS.md loading, the cache settings, input and
slash command parsing, the compaction steps (everything except the API
call), the status line, and the streaming parser.

The Bash tests run real commands. They check pipes and exit codes, stderr,
the working directory, empty stdin, the timeout kill, invalid UTF-8, and
that `git commit` fails instead of waiting for an editor. The streaming
tests feed in a sample event stream, both whole and split into chunks as
small as one byte, and check that every split gives the same reply.

None of them call the API. The script exits with a non-zero status if any
test fails, so it works in CI or a git hook.

## Limitations

- **Compaction is manual.** If you never type `/compact`, a very long
  session will eventually hit the model's context limit. A compacted session
  only remembers what the summary kept.
- **`max_tokens` during a tool call.** Each reply may use up to 128,000
  output tokens, the most these models accept. If a reply is cut off at that
  limit partway through a tool call, the harness treats it as the end of the
  turn, and the next request is likely to fail. The status line shows
  `stop_reason=max_tokens` when this happens. The limit is per reply; the
  conversation as a whole can be far larger.
- **Bash forgets between calls.** `cd` and `export` last for one command
  only.
- **A timeout kills the shell and its direct children.** A grandchild
  process that detached itself (a daemon, `nohup`) can keep running.
- **Interactive programs can't be used.** Anything that needs a terminal
  (`vim`, `git rebase -i`, `top`) gets empty stdin and no TTY. It either
  fails or runs until the timeout.
- **Tool calls aren't shown while they stream.** Only text is printed as it
  arrives; a tool call appears once its input is complete.
- **Tools run one at a time,** even when the model asks for several at once.
- **Read has no offset.** Large files are cut at 50,000 characters; the
  model can use `grep -n` and `sed -n` in Bash to find and print the part it
  needs.
- **Nothing is saved.** History is lost when you exit, and a crash (for
  example Ctrl-C) loses it too.
- **A missing `API_KEY` crashes the session** on the first request instead
  of offering a retry. `source .env` before you start.
- **Code changes need a restart.** If the agent edits `harness.exs`, the
  change takes effect in the next session.
