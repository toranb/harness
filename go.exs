case System.argv() do
  [] -> Go.run("Read mix.exs and write a one-paragraph summary of this project to SUMMARY.md.")
  args -> Go.run(Enum.join(args, " "))
end
