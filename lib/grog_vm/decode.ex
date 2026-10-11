defmodule GrogVM.Decode do
  @moduledoc """
  Decodes SCUMM v5 bytecode into `GrogVM.Instruction`s.

      {:ok, instruction} = GrogVM.Decode.instruction(code, 0)
      {:ok, program} = GrogVM.Decode.program(code, [0])

  `program/2` follows every path from the entry offsets — falling through, jumping,
  failing a test, and resuming where a cutscene's override sends it — and returns every
  instruction reached, by offset.
  """

  alias GrogVM.Decode.{Cursor, Operands, Table}
  alias GrogVM.Instruction

  @type program :: %{non_neg_integer() => Instruction.t()}
  @type error ::
          {:bad_instruction, non_neg_integer(), byte()}
          | {:outside_code, non_neg_integer()}
          | {:inside_instruction, non_neg_integer()}

  @doc "Decodes the instruction at `offset`."
  @spec instruction(binary(), non_neg_integer()) :: {:ok, Instruction.t()} | {:error, error()}
  def instruction(code, offset) when offset >= 0 and offset < byte_size(code) do
    opcode = :binary.at(code, offset)
    name = Table.name(opcode)
    {read, cursor} = Operands.read(name, Cursor.new(code, offset + 1, opcode))

    {:ok,
     %Instruction{
       offset: offset,
       next: cursor.pos,
       opcode: opcode,
       op: name,
       args: read.args,
       result: read.result,
       target: read.target
     }}
  rescue
    _error in [MatchError, KeyError, CaseClauseError, FunctionClauseError] ->
      {:error, {:bad_instruction, offset, :binary.at(code, offset)}}
  end

  def instruction(_code, offset), do: {:error, {:outside_code, offset}}

  @doc "Decodes every instruction reachable from `entries`."
  @spec program(binary(), [non_neg_integer()]) :: {:ok, program()} | {:error, error()}
  def program(code, entries), do: walk(code, entries, %{})

  @doc "The offsets execution may continue at after `instruction`."
  @spec successors(Instruction.t()) :: [non_neg_integer()]
  def successors(%Instruction{op: op}) when op in [:stop_object_code, :chain_script], do: []
  def successors(%Instruction{op: :jump_relative, target: target}), do: [target]

  def successors(%Instruction{op: :begin_override, args: [{:begin, abort}]}),
    do: [abort + 3, abort]

  def successors(%Instruction{target: nil, next: next}), do: [next]
  def successors(%Instruction{target: target, next: next}), do: [next, target]

  defp walk(_code, [], program), do: check_overlaps(program)

  defp walk(code, [offset | rest], program) when is_map_key(program, offset),
    do: walk(code, rest, program)

  defp walk(code, [offset | rest], program) do
    with {:ok, instruction} <- instruction(code, offset) do
      walk(code, successors(instruction) ++ rest, Map.put(program, offset, instruction))
    end
  end

  defp check_overlaps(program) do
    program
    |> Map.values()
    |> Enum.sort_by(& &1.offset)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [first, second] -> first.next > second.offset end)
    |> overlap_result(program)
  end

  defp overlap_result(nil, program), do: {:ok, program}

  defp overlap_result([_first, second], _program),
    do: {:error, {:inside_instruction, second.offset}}
end
