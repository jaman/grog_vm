defmodule GrogVM.DecodeTest do
  use ExUnit.Case, async: true

  alias GrogVM.Decode

  test "a string escape names the string resource itself, not a variable" do
    code = <<0xD8, 0x0F, "a", 0xFF, 7, 14, 0, 0, 0xA0>>
    {:ok, print} = Decode.instruction(code, 0)
    assert print.args == [[{:text, [["a", {:string, 14}]]}]]
  end

  test "a cutscene override goes on past its jump, and a skip resumes at the jump" do
    code = <<0x58, 1, 0x18, 1, 0, 0x80, 0x80, 0xA0>>
    {:ok, override} = Decode.instruction(code, 0)
    assert override.args == [{:begin, 2}]
    assert Decode.successors(override) == [5, 2]
    assert {:ok, program} = Decode.program(code, [0])
    assert Map.keys(program) |> Enum.sort() == [0, 2, 5, 6, 7]
  end

  test "a comparison jumps relative to the end of the instruction" do
    code = <<0x48, 5, 0, 7, 0, 2, 0, 0x80, 0x80, 0xA0>>
    {:ok, compare} = Decode.instruction(code, 0)
    assert compare.args == [{:var, {:global, 5}}, {:imm, 7}]
    assert compare.next == 7
    assert compare.target == 9
  end
end
