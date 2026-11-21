case System.argv() do
  [] ->
    case IO.gets("> ") do
      prompt when is_binary(prompt) -> Go.run(String.trim(prompt))
      _ -> :ok
    end

  args ->
    Go.run(Enum.join(args, " "))
end
