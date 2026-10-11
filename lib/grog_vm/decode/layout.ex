defmodule GrogVM.Decode.Layout do
  @moduledoc """
  Reads a list of parameters described by a layout, the form most instructions take.

  Layout items, in the order the bytes appear:

    * `:result` — the variable the instruction stores into,
    * `:b1`, `:b2`, `:b3` — a byte parameter whose kind bit is `0x80`, `0x40`, `0x20`,
    * `:w1`, `:w2`, `:w3` — a word parameter with the same kind bits,
    * `:byte`, `:signed_word` — a constant read as it is,
    * `:var` — a variable reference,
    * `:list` — a `0xFF`-terminated list of word parameters,
    * `:text` — a message,
    * `:sub_op` — a byte that becomes the selector for the parameters after it,
    * `:jump` — a relative jump, kept as the instruction's target.
  """

  alias GrogVM.Decode.Cursor

  @type item ::
          :result
          | :b1
          | :b2
          | :b3
          | :w1
          | :w2
          | :w3
          | :byte
          | :signed_word
          | :var
          | :list
          | :text
          | :sub_op
          | :jump
  @type read :: %{args: [term()], result: term(), target: non_neg_integer() | nil}

  @doc "Reads `layout` from `cursor`."
  @spec read([item()], Cursor.t()) :: {read(), Cursor.t()}
  def read(layout, cursor) do
    {read, cursor} = Enum.reduce(layout, {%{args: [], result: nil, target: nil}, cursor}, &item/2)
    {%{read | args: Enum.reverse(read.args)}, cursor}
  end

  @doc "Reads `layout` from `cursor` and returns only the parameters."
  @spec args([item()], Cursor.t()) :: {[term()], Cursor.t()}
  def args(layout, cursor) do
    {%{args: args}, cursor} = read(layout, cursor)
    {args, cursor}
  end

  defp item(:result, {read, cursor}) do
    {ref, cursor} = Cursor.var(cursor)
    {%{read | result: ref}, cursor}
  end

  defp item(:jump, {read, cursor}) do
    {target, cursor} = Cursor.jump(cursor)
    {%{read | target: target}, cursor}
  end

  defp item(:sub_op, {read, cursor}) do
    {_selector, cursor} = Cursor.sub_op(cursor)
    {read, cursor}
  end

  defp item(item, {read, cursor}) do
    {value, cursor} = value(item, cursor)
    {%{read | args: [value | read.args]}, cursor}
  end

  defp value(:b1, cursor), do: Cursor.byte_param(cursor, 0x80)
  defp value(:b2, cursor), do: Cursor.byte_param(cursor, 0x40)
  defp value(:b3, cursor), do: Cursor.byte_param(cursor, 0x20)
  defp value(:w1, cursor), do: Cursor.word_param(cursor, 0x80)
  defp value(:w2, cursor), do: Cursor.word_param(cursor, 0x40)
  defp value(:w3, cursor), do: Cursor.word_param(cursor, 0x20)
  defp value(:list, cursor), do: Cursor.word_list(cursor)
  defp value(:text, cursor), do: Cursor.text(cursor)

  defp value(:var, cursor) do
    {ref, cursor} = Cursor.var(cursor)
    {{:var, ref}, cursor}
  end

  defp value(:byte, cursor) do
    {byte, cursor} = Cursor.byte(cursor)
    {{:imm, byte}, cursor}
  end

  defp value(:signed_word, cursor) do
    {word, cursor} = Cursor.signed_word(cursor)
    {{:imm, word}, cursor}
  end
end
