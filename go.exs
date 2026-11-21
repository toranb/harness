{opts, args, _} = OptionParser.parse(System.argv(), strict: [debug: :boolean])
Application.put_env(:go, :debug, Keyword.get(opts, :debug, false))

case args do
  [] ->
    case IO.gets("> ") do
      prompt when is_binary(prompt) -> Go.run(String.trim(prompt))
      _ -> :ok
    end

  args ->
    Go.run(Enum.join(args, " "))
end
