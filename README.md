# go

A small coding agent in one Elixir file, written to learn how a model and a
harness work together. `harness.exs` sends your prompt to Claude, runs the
tools the model asks for on your machine, sends the results back, and repeats
until the model has an answer. It prints every step as it goes.

It is built to get things done fast, with no brakes: the model has a real
bash shell and your permissions, and nothing asks before a tool runs. Read
[Safety](#safety) before you point it at anything you care about.

```zsh
source .env
elixir harness.exs "Find the line defining @max_output in harness.exs and tell me its value in one line."
```

```text
[turn 1] stop_reason=tool_use | prompt 1861 tokens (cache read 0, cache write 1857, uncached 4) | output 65 tokens
-> Bash %{"command" => "grep -rn \"@max_output\" . --include=*.exs"}
<- ok, 439 chars: ./harness.exs:123:  @max_output 50_000
Line 123 of harness.exs: `@max_output 50_000`
[turn 2] stop_reason=end_turn | prompt 2119 tokens (cache read 1857, cache write 260, uncached 2) | output 24 tokens

>
```

One prompt, two requests. In the first, the model asked for a tool
(`stop_reason=tool_use`); the harness ran the `grep` and sent back the
output. In the second, it answered without a tool call (`end_turn`), so its
turn is over and the harness waits at `>` for your next message.

## Running it

You need Elixir and Erlang (versions in `.tool-versions`), bash, and an
Anthropic API key, on Linux or macOS. The only dependency, the Req HTTP
client, is fetched by `Mix.install` on the first run. There is no mix
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

At `>` each message continues the same conversation. A few inputs are
commands instead:

```text
  /help               list these commands
  /compact [focus]    summarize the conversation to free up context (optional focus)
  exit, quit, Ctrl-D  end the session
```

The conversation is not saved after you exit.

## Reading the output

- **`[turn N]`** counts requests to the model, not your messages. One
  message can take many turns: "fix the failing test" might be Read, Edit,
  `mix test`, Edit, `mix test`, then an answer.
- **`stop_reason`** is why the model stopped. It is the only thing the loop
  looks at (see below).
- **`prompt N tokens`** is the size of the whole request. Watch it grow:
  every request resends the entire conversation.
- **`cache read` / `cache write`** show prompt caching at work. After the
  first request, almost all of the prompt should be a cache read.
- **`->`** is a tool call and its input; **`<-`** is `ok` or `error`, the
  result's length and the start of its first line. The model always gets
  the full result.

## How it works

The whole agent is a loop:

```text
  you type a prompt
        │
        ▼
 ┌─► send tools + system prompt + the whole conversation to the model
 │      │
 │      ▼
 │   stop_reason == "tool_use"?
 │      │yes                              │no
 │      ▼                                 ▼
 │   run each tool call, append        print the reply, wait at >
 │   the results to the conversation        │
 └──────┴───────────────────────────────────┘ you type the next message
```

**The model decides when it's done, not the harness.** The decision is one
line in `loop/2`:

```elixir
if response["stop_reason"] == "tool_use" do
```

As long as the model keeps calling tools, the loop keeps running them.
When it replies without a tool call, control comes back to you. There is no
cap on tool calls per turn.

**The model has no memory between requests.** Each request carries
everything: the five tool definitions, the system prompt, and every message,
tool call and tool result so far. That is why caching matters and why
`/compact` exists.

The system prompt tells the model what it is running in, the working
directory, and facts about the machine: OS, bash version and which common
programs are installed (detected once per session). On macOS it also warns
that `sed`, `grep` and `find` are the BSD versions. Run with `--debug` to see
exactly what the model receives.

## Tools

| Tool | What it does |
|---|---|
| **Read** | Returns a file's contents |
| **Write** | Creates or overwrites a file, creating folders as needed |
| **Edit** | Replaces one exact, unique occurrence of `old_string` with `new_string` |
| **WebFetch** | HTTP GET of a URL. A 4xx or 5xx comes back as an error, so the model can try something else |
| **Bash** | Runs any command with `bash -c` in the working directory and returns its output and exit code |

Every result is cut at 50,000 characters, with a note telling the model to
use `grep -n` and `sed -n` to find the rest. A failed tool call (a missing
file, an Edit that doesn't match, a non-zero exit) goes back to the model as
an error, and it usually fixes the call and tries again.

**Bash** is a real shell: pipes, redirects, git, curl, mix, package
managers, anything installed. The harness only makes sure a command can't
hang the session, since there is no terminal for it to talk to:

- Stdin is empty, and editors and pagers are disabled, so `git commit`
  without `-m` fails instead of waiting for an editor.
- Each call is a fresh shell: `cd` and `export` don't carry over.
- A command is killed after 120 seconds unless the model asks for a longer
  timeout (up to 600).
- A background job (`server &`) doesn't block the call. The model is told to
  redirect its output to a log, save its PID, and `kill` it when done.
- The harness's `API_KEY` is removed from every command's environment.

## AGENTS.md

If the working directory has an `AGENTS.md`, it is put in front of your
first message, and the model follows it as your instructions for the whole
session. Use it for the things you'd tell a new teammate: how to run the
tests, code style, what not to touch.

## Compaction (/compact)

A long session gets slow, expensive, and eventually hits the model's
context limit. `/compact` replaces the conversation with a summary:

```text
> /compact
> /compact keep the exact error messages     # optional focus
```

It only runs when you type it. The status line suggests it once a prompt
passes 150,000 tokens.

The harness asks the model to summarize the conversation, keeping
decisions, constraints in your own words, problems hit, where things stand,
what's still open, and exact names and numbers. It prints the summary, then
starts a fresh conversation holding only `AGENTS.md` (if any) and that
summary. Your next message continues from there.

**The summary is all the model remembers**, so read it. If something
important is missing, say it in your next message. In testing, a 22-message
session shrank from about 8,900 to 3,300 tokens, and the model still
recalled the user's constraints word for word, an unrelated number from
earlier, and what was planned next. It doesn't keep file contents, so
expect it to re-read a file before editing it.

## Safety

There isn't any, on purpose.

- **Every tool call runs immediately, with your permissions.** Bash can
  `rm -rf`, `git push --force` or `curl ... | sh`. Write and Edit can change
  any file you can.
- **Nothing is filtered.** No allowlist, no confirmation. The system prompt
  is the only guidance, and the model can ignore it.
- **The network is open.** The model can send anything it reads, including
  `.env`, to any URL. Only the harness's own API key is kept out of Bash's
  environment.
- **Anything the model reads can steer it:** AGENTS.md, a web page, a code
  comment. Only use it on projects and content you trust.
- **`--debug` prints everything,** file contents included. Don't share it.

If you want brakes, run it in a container, a throwaway VM, or as a user that
can't reach anything you care about. Commit before a session so git can get
your work back.

## Adding a tool

The model only ever sees a schema; the harness decides what actually runs.
Since Bash can already run anything, add a tool when it does something the
shell can't, or does it more reliably. Two edits to `harness.exs`:

1. **Add a schema to `@tools`.** The `description` is how the model decides
   when to call it, so say what it returns and when not to use it.
2. **Add an `execute_tool/2` clause** above the catch-all clause. It gets
   the input as a map with string keys and returns `{output, is_error}`.
   Pass long output through `truncate/1`.

For example, an `Ask` tool that asks you a question in the terminal
(something Bash can't do, since its stdin is empty):

```elixir
# in @tools
%{
  name: "Ask",
  description:
    "Ask the user a question in the terminal and return their answer. Use it only " <>
      "for decisions or facts that only the user has.",
  input_schema: %{
    type: "object",
    properties: %{question: %{type: "string", description: "The question to ask"}},
    required: ["question"],
    additionalProperties: false
  },
  strict: true
}

# above the catch-all execute_tool/2
def execute_tool("Ask", %{"question" => question}) do
  IO.puts("\n[question] " <> question)

  case read_line("answer> ") do
    :eof -> {"The user did not answer.", true}
    answer -> {answer, false}
  end
end
```

The system prompt picks up the new tool name automatically. Restart the
harness to load it, and add a test in `harness_test.exs` that calls
`Go.execute_tool("Ask", ...)` directly.

## Finding your way around harness.exs

It is one module, `Go`, of about 1,100 lines. Banner comments
(`# ---- The agent loop ----`) mark every part except the first:

- **The request** (above the loop): `system_prompt/2`, `first_message/2`
  (AGENTS.md), `request_body/2` (model, `max_tokens`, cache settings), and
  `call_model/2`, which sits after compaction.
- **The agent loop:** `run/1`, `loop/2`, `next_prompt/2`, `run_tools/1`.
- **Compaction:** `compact/3` and the summary prompt.
- **Streaming:** rebuilding the reply from server-sent events so text
  prints as it's written.
- **Tools:** `@tools` at the top, `execute_tool/2` and the Bash helpers at
  the bottom.

The tests (`elixir harness_test.exs`) load the file without starting a
session and never call the API. The Bash and WebFetch tests run real
commands and a local HTTP server.

## Limitations

- **Compaction is manual.** A very long session without `/compact` will
  eventually hit the context limit.
- **Interactive programs can't be used.** Anything that needs a terminal
  (`vim`, `git rebase -i`, `top`) fails or runs until the timeout.
- **A timeout kills the shell and its direct children.** A detached
  grandchild (a daemon, `nohup`) can keep running.
- **Tools run one at a time,** even when the model asks for several at once.
- **Nothing is saved.** History is lost when you exit or press Ctrl-C.
- **A reply cut off at `max_tokens` during a tool call** leaves the
  conversation in a state the API rejects. You'll see
  `stop_reason=max_tokens` and an error; type `exit`. It takes a single
  reply of about 128,000 tokens, so in practice you won't hit it.
- **Code changes need a restart.** If the agent edits `harness.exs`, the
  change takes effect in the next session.
