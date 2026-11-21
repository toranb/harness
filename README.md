# go

A small coding agent in one Elixir file, written to learn how a model and a
harness work together. `harness.exs` sends your prompt to Claude, runs the
tools the model asks for on your machine, sends the results back, and repeats
until the model has an answer. The loop is a handful of short functions, and
it prints every step as it runs.

```zsh
source .env                               # API_KEY=..., optional API_MODEL=...
elixir harness.exs "Grep harness.exs for the line defining @max_output and tell me its value in one line."
```

```text
[turn 1] stop_reason=tool_use | prompt 2105 tokens (cache read 0, cache write 2101, uncached 4) | output 103 tokens
-> Grep %{"max_results" => 5, "path" => "@max_output", "pattern" => "@max_output"}
<- error, 38 chars: No such file or directory: @max_output
[turn 2] stop_reason=tool_use | prompt 2226 tokens (cache read 2101, cache write 123, uncached 2) | output 163 tokens
-> Grep %{"max_results" => 5, "path" => "harness.exs", "pattern" => "@max_output"}
<- ok, 341 chars: harness.exs:160:  @max_output 50_000
`@max_output` is set to `50_000` on line 160 of harness.exs.
[turn 3] stop_reason=end_turn | prompt 2533 tokens (cache read 2224, cache write 307, uncached 2) | output 28 tokens

>
```

This one prompt took three requests. The model's first Grep used the wrong
path and got an error back. It fixed the path, found the line, then answered
without asking for a tool, which ended its turn (`end_turn`). The harness is
now waiting at `>` for your next message.

## Contents

- [Running it](#running-it)
- [Features](#features)
- [From prompt to reply](#from-prompt-to-reply)
- [How the agent decides to stop](#how-the-agent-decides-to-stop)
- [What the model sees](#what-the-model-sees)
- [Tools](#tools)
- [Reading the output](#reading-the-output)
- [Streaming](#streaming)
- [Prompt caching](#prompt-caching)
- [Compaction (/compact)](#compaction-compact)
- [Safety](#safety)
- [Code map](#code-map)
- [Tests](#tests)
- [Limitations](#limitations)

## Running it

You need Elixir and Erlang (versions in `.tool-versions`), `curl`, and an
Anthropic API key. Req, the HTTP client, is the only dependency. `Mix.install`
downloads it on the first run and caches it after that. There is no mix
project to set up.

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
- **Eight tools:** Read, Write, Edit, Grep, WebFetch, Curl, Mix and Git
  ([details](#tools)). There is no shell tool, so the model can only do what
  these tools allow.
- **A system prompt** that tells the model what this harness is, which
  directory it's in, which tools it has, and that there is no shell.
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
   That is the model name, `max_tokens`, the system prompt, the eight tool
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
Read, Edit, Mix test, Edit, Mix test, then a final answer: six requests in one
turn, each a little bigger than the last.

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
system prompt's guidance (verify changes with Mix, say so if a tool is
missing) shape when it stops.

The *session* ends only when you say so: `exit`, `quit`, Ctrl-D, or `exit` at
the retry prompt after an API error.

## What the model sees

Every request has the same four parts, in this order:

1. **Tools**: the eight tool definitions in `@tools`. Each has a name, a
   description that tells the model when and how to use it, and a JSON input
   schema. `strict: true` makes the API guarantee that tool inputs match the
   schema.
2. **System prompt** (`system_prompt/1`): what this harness is, the working
   directory, the tool names (built from `@tools` so the two can't drift),
   that there is no shell, to verify code changes with Mix, which Git
   subcommands and stash actions it has (built from `@git_subcommands` and
   `@git_stash_actions`), to only stage or commit with Git when you ask, and
   to keep replies short.
3. **First user message** (`first_message/2`): the contents of `AGENTS.md`
   wrapped in `<project_instructions>`, if the file exists, followed by your
   prompt.
4. **The rest of the conversation**: every reply, tool call, tool result and
   message since then, in order.

Run with `--debug` to see the full request for every turn.

## Tools

| Tool | What it does | Limits |
|---|---|---|
| **Read** | Returns a file's contents | Cut at 50,000 characters |
| **Write** | Creates or overwrites a file, creating folders as needed | |
| **Edit** | Replaces one exact occurrence of `old_string` with `new_string` | `old_string` must not be empty and must appear exactly once |
| **Grep** | Regex search of a file or folder, returning `file:line:text` | Optional `only_matching`, `case_insensitive`, `max_results` (default 100). Folder searches skip `_build`, `deps`, `node_modules` and hidden folders |
| **WebFetch** | Plain HTTP GET of a URL | 30-second timeout, body cut at 50,000 characters |
| **Curl** | Runs the real `curl` with an array of arguments, for headers, cookies, methods and request bodies | Adds `--silent --show-error --max-time 60` and reports the HTTP status and exit code. Output cut at 50,000 characters |
| **Mix** | Runs one mix task in the working directory | Only `deps.get`, `compile`, `test` and `format`, with no extra arguments |
| **Git** | Runs one git subcommand with an array of arguments in the working directory, to inspect and search history and make local commits | Only `status`, `log`, `diff`, `show`, `add`, `commit` and `stash`. Some flags are refused (see below). Output cut at 50,000 characters |

Without a shell, the model can't pipe output between programs. To search a
large web page it saves the page with `Curl -o page.html`, then runs `Grep`
on the file. The system prompt and the Curl description both point it to
this approach.

### The Git tool

Git lets the agent search history and make local commits, but nothing that
talks to a remote (`push`, `pull`, `fetch`) or rewrites history (`reset`,
`rebase`, `commit --amend`). The system prompt lists the subcommands and
stash actions it has, generated from the same lists the tool checks, and
says it can't talk to a remote, reset, rebase or amend. It tells the model
to use Git freely for reading, but to stage, commit or stash only when you
ask, and to check `status` and `diff` first. The Git tool's own description
repeats the details, including the refused flags.

Searching history uses `git log`:

| To find | Arguments |
|---|---|
| Commits whose message mentions a word | `log --oneline --grep=cache` (add `-i` to ignore case) |
| Commits that added or removed some text | `log --oneline -S "hello cache"` |
| Commits whose changes match a regex | `log --oneline -G "def \w+_stream"` |
| One commit in full | `show <sha>` |

`git_refusal/2` checks every call before it runs. It refuses:

| Refused | Why |
|---|---|
| Any subcommand not in `@git_subcommands` | Keeps the tool to reading history and local commits |
| `commit --amend` | Rewrites the last commit |
| `commit --no-verify` / `-n` | Skips the repo's commit hooks |
| `add --force` / `-f` | Adds files `.gitignore` excludes, such as `.env` |
| `stash drop`, `stash clear` | Deletes stashes (allowed: `push`, `list`, `show`, `pop`, `apply`) |
| `--interactive`, `--patch`, `--edit` and their short forms on `add`, `commit`, `stash` | They wait for a terminal or editor, which would hang the session |
| `--output`, `--ext-diff` on any subcommand | Writes a file outside git's control / runs an external program |

The check also catches bundled short flags (`-fA` contains `-f`) and long
flags with a value (`--output=x`), and skips everything after `--`, which
git treats as file paths. The subcommand is always the first argument, so the
model can't add global options such as `-c` or `--git-dir` in front of it.
Git runs with `GIT_EDITOR=true` and no pager: a commit without `-m` fails
instead of waiting for an editor that will never open.

In a test in a throwaway clone of this repo, the agent found the streaming
commit with `log --grep` and `log -S`, staged and committed one new file
after checking `diff --cached`, and when asked to amend it, explained that
the tool refuses `--amend`.

When a tool fails, for example because a file is missing or an Edit
`old_string` isn't found, the error message goes back to the model as a
result with `is_error: true`. Models usually fix their call and try again;
the example at the top of this README shows this happening.

To add a tool: add its definition to `@tools` and add an `execute_tool/2`
clause with the same name that returns `{output, is_error}`. The system
prompt picks up the new name automatically.

## Reading the output

```text
[turn 2] stop_reason=tool_use | prompt 2226 tokens (cache read 2101, cache write 123, uncached 2) | output 163 tokens
-> Grep %{"path" => "harness.exs", "pattern" => "@max_output"}
<- ok, 341 chars: harness.exs:160:  @max_output 50_000
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
   same folder.
2. **Automatic, at the end of the conversation** (the top-level
   `cache_control`). The API places it on the last block and moves it as the
   conversation grows, so each request reads the previous request from cache
   and only pays full price for what is new.

In the example above, turn 2 read 2,101 tokens from cache and processed only
125 new ones. Cache entries last 5 minutes from their last use. Anything that
changes the cached bytes, such as a different tool list, system prompt or
model, causes a miss.

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
   (`compacted_messages/2`). Your next message is added to it.

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

This is a learning tool, not a sandbox.

- **Tools run with your permissions, and nothing asks you first.** Write and
  Edit can change any file you can change, and Read can read any file you can
  read, including outside the working directory.
- **There is no shell.** Curl, Mix and Git call their programs directly
  with an argument list, so an argument like `"x; rm -rf ~"` is passed as
  text and never run as a command. Mix only accepts its four allowed tasks.
- **Git can commit, but only locally.** It can't push, reset, rebase or
  amend, and it refuses `add --force`, so ignored files such as `.env` stay
  out. A plain `git add .` still stages anything that isn't ignored, so keep
  secrets in `.gitignore`. Commits run the repo's own hooks, as they would
  for you.
- **Curl and WebFetch can reach any URL.** The model can send what it reads
  (files, `.env`) to the network if it decides to.
- **AGENTS.md is followed as your instructions.** Only run the agent in
  projects whose `AGENTS.md` you trust.
- **`--debug` prints everything,** including file contents and any cookies
  or tokens passed to Curl. Don't share that output.

## Code map

`harness.exs`, top to bottom:

| Part | What it is |
|---|---|
| `Mix.install([{:req, "0.7.5"}])` | The single dependency, pinned so every install is the same |
| `@mix_tasks`, `@git_subcommands`, `@git_blocked_flags`, `@git_stash_actions` | What the Mix and Git tools allow and refuse |
| `@tools` | The eight tool definitions sent to the API |
| `@max_output`, `@grep_skip_dirs` | The 50,000-character output limit and the folders Grep skips |
| `system_prompt/1`, `first_message/2`, `request_body/2` | What goes into each request |
| `run/1`, `start/1`, `loop/2`, `next_prompt/2`, `add_user_text/2` | The agent loop |
| `call_model/2` | One streamed request to the Messages API; returns `{:ok, response}` or `{:error, reason}` |
| `new_stream/0`, `consume_chunk/2`, `apply_event/2`, `finish_stream/1` | Rebuilding the response from the streamed events |
| `turn_status/3`, `run_tools/1`, `result_summary/2` | Running tools and printing what happens |
| `@commands`, `help_text/0` | The commands `/help` lists; add a new one here and in `next_prompt/2` |
| `read_user_input/0`, `parse_input/1` | The `>` prompt: messages, `/commands` and `exit` |
| `compact/3`, `compaction_prompt/1`, `extract_summary/1`, `compacted_messages/2` | `/compact` |
| `execute_tool/2` | One clause per tool |
| `git_refusal/2` | Why a Git call is refused, or `nil` |
| `truncate/1`, `files_under/1`, `grep_lines/4` | Helpers for the tools |
| Entry point (bottom of file) | Parses `--debug` and calls `Go.run/1`; skipped when the tests load the file |

## Tests

```zsh
elixir harness_test.exs
```

The tests load `harness.exs` without starting a session and check the tools,
the system prompt, AGENTS.md loading, the cache settings, input and slash
command parsing, the compaction steps (everything except the API call), the
status line, and the streaming parser. The parser tests feed in a sample
event stream, both whole and split into chunks as small as one byte, and
check that every split gives the same reply. None of them call the API. The script exits with a non-zero
status if any test fails, so it works in CI or a git hook.

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
- **Tool calls aren't shown while they stream.** Only text is printed as it
  arrives; a tool call appears once its input is complete.
- **Tools run one at a time,** even when the model asks for several at once.
- **Read has no offset.** Large files are cut at 50,000 characters; use Grep
  to find the part you need.
- **Nothing is saved.** History is lost when you exit, and a crash (for
  example Ctrl-C) loses it too.
- **Code changes need a restart.** If the agent edits `harness.exs`, the
  change takes effect in the next session.
