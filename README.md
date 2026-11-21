# go

A tiny single-file agent harness over the Claude Messages API, written to
learn how a model and a harness fit together. Needs Elixir and `curl`; Req
is pulled in by `Mix.install` on first run.

```zsh
source .env                              # API_KEY, optional API_MODEL
elixir harness.exs                       # prompts at >
elixir harness.exs "your prompt here"
elixir harness.exs --debug "your prompt" # print every full request
elixir harness_test.exs                  # unit tests, no API calls
```

Tools: Read, Write, Edit, Grep, WebFetch, Curl (native curl, no shell) and
Mix (deps.get, compile, test, format). If the working directory has an
`AGENTS.md`, it is put in front of the first prompt.
