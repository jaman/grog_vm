defmodule GrogVM.Instruction do
  @moduledoc """
  One decoded SCUMM v5 instruction.

    * `offset`, `next` — where it starts and where the following instruction starts,
    * `opcode` — the byte it was read from, `op` — its name,
    * `args` — its parameters in order: `{:imm, integer}`, `{:var, GrogVM.Var.t()}`,
      lists of those, `GrogVM.Text.t()` messages, and `{name, args...}` sub-operations,
    * `result` — the variable it stores into, or `nil`,
    * `target` — where a jump goes, or for a test where it goes when the test fails,
    * `nested` — for an `expression`, its steps; `{:op, instruction}` steps run an
      instruction whose result is pushed.
  """

  alias GrogVM.Var

  @enforce_keys [:offset, :next, :opcode, :op, :args, :result, :target]
  defstruct [:offset, :next, :opcode, :op, :args, :result, :target, nested: nil]

  @type operand :: {:imm, integer()} | {:var, Var.t()}
  @type t :: %__MODULE__{
          offset: non_neg_integer(),
          next: non_neg_integer(),
          opcode: byte(),
          op: atom(),
          args: [term()],
          result: Var.t() | nil,
          target: non_neg_integer() | nil,
          nested: [term()] | nil
        }
end
