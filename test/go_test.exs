defmodule GoTest do
  use ExUnit.Case
  doctest Go

  test "adds two numbers" do
    assert Go.run(1, 2) == 3
  end
end
