defmodule Go do

  def run(a, b) do
    x = a + b
    IO.inspect(x)
    x
  end

end

Go.run(1, 2)
