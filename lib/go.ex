defmodule Go do
  @moduledoc """
  Tiny hello world module.
  """

  @doc """
  Adds two numbers, prints the result, and returns it.

  ## Examples

      iex> Go.run(1, 2)
      3

  """
  def run(a, b) do
    x = a + b
    IO.inspect(x)
    x
  end
end
