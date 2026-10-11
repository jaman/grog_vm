defmodule GrogVM.Decode.Cursor do
  @moduledoc """
  A position in a script's bytes while one instruction is decoded, with the byte that
  selects how the next parameters are read.

  In SCUMM v5 the opcode byte (and, inside a sub-operation, the sub-operation byte)
  carries one bit per leading parameter — `0x80` for the first, `0x40` for the second,
  `0x20` for the third — set when that parameter is a variable rather than a constant.
  """

  alias GrogVM.{Text, Var}

  @enforce_keys [:code, :pos, :op]
  defstruct [:code, :pos, :op]

  @type t :: %__MODULE__{code: binary(), pos: non_neg_integer(), op: byte()}
  @type operand :: {:imm, integer()} | {:var, Var.t()}

  @doc "A cursor at `pos` in `code`, reading parameters by `op`."
  @spec new(binary(), non_neg_integer(), byte()) :: t()
  def new(code, pos, op), do: %__MODULE__{code: code, pos: pos, op: op}

  @doc "Reads one unsigned byte."
  @spec byte(t()) :: {byte(), t()}
  def byte(%__MODULE__{code: code, pos: pos} = cursor) do
    <<_::binary-size(^pos), value, _::binary>> = code
    {value, %{cursor | pos: pos + 1}}
  end

  @doc "Reads one byte and makes it the byte that selects parameter kinds."
  @spec sub_op(t()) :: {byte(), t()}
  def sub_op(cursor) do
    {value, cursor} = byte(cursor)
    {value, %{cursor | op: value}}
  end

  @doc "Reads one unsigned little-endian word."
  @spec word(t()) :: {non_neg_integer(), t()}
  def word(%__MODULE__{code: code, pos: pos} = cursor) do
    <<_::binary-size(^pos), value::little-16, _::binary>> = code
    {value, %{cursor | pos: pos + 2}}
  end

  @doc "Reads one signed little-endian word."
  @spec signed_word(t()) :: {integer(), t()}
  def signed_word(%__MODULE__{code: code, pos: pos} = cursor) do
    <<_::binary-size(^pos), value::little-signed-16, _::binary>> = code
    {value, %{cursor | pos: pos + 2}}
  end

  @doc "Reads a variable reference."
  @spec var(t()) :: {Var.t(), t()}
  def var(%__MODULE__{code: code, pos: pos} = cursor) do
    {ref, pos} = Var.read(code, pos)
    {ref, %{cursor | pos: pos}}
  end

  @doc "Reads a byte parameter: a variable when `mask` is set in the selecting byte."
  @spec byte_param(t(), byte()) :: {operand(), t()}
  def byte_param(cursor, mask), do: param(cursor, mask, &byte/1)

  @doc "Reads a word parameter: a variable when `mask` is set in the selecting byte."
  @spec word_param(t(), byte()) :: {operand(), t()}
  def word_param(cursor, mask), do: param(cursor, mask, &signed_word/1)

  @doc """
  Reads a list of word parameters, each preceded by a byte that selects its kind with
  `0x80`, ending at a `0xFF` byte.
  """
  @spec word_list(t()) :: {[operand()], t()}
  def word_list(cursor), do: word_list(cursor, [])

  @doc "Reads a relative jump and returns its absolute target."
  @spec jump(t()) :: {non_neg_integer(), t()}
  def jump(cursor) do
    {offset, cursor} = signed_word(cursor)
    {cursor.pos + offset, cursor}
  end

  @doc "Reads a NUL-terminated message with its escape codes."
  @spec text(t()) :: {Text.t(), t()}
  def text(%__MODULE__{code: code, pos: pos} = cursor) do
    {message, pos} = Text.read(code, pos)
    {message, %{cursor | pos: pos}}
  end

  defp param(%__MODULE__{op: op} = cursor, mask, _constant) when Bitwise.band(op, mask) != 0 do
    {ref, cursor} = var(cursor)
    {{:var, ref}, cursor}
  end

  defp param(cursor, _mask, constant) do
    {value, cursor} = constant.(cursor)
    {{:imm, value}, cursor}
  end

  defp word_list(cursor, acc) do
    {selector, cursor} = byte(cursor)
    word_list_item(selector, cursor, acc)
  end

  defp word_list_item(0xFF, cursor, acc), do: {Enum.reverse(acc), cursor}

  defp word_list_item(selector, cursor, acc) do
    {value, cursor} = word_param(%{cursor | op: selector}, 0x80)
    word_list(cursor, [value | acc])
  end
end
