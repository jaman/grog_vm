defmodule GrogVM.Var do
  @moduledoc """
  A SCUMM v5 variable reference.

  A variable word names a global word variable (no bit of `0xF000` set), a bit variable
  (`0x8000`), or a local of the running script (`0x4000`). With `0x2000` set, a second
  word follows: with its own `0x2000` set it names a variable whose value is added to the
  first word, otherwise its low 12 bits are added; the sum (without `0x2000`) is then
  classified as above.

      GrogVM.Var.classify(0x4003)
      #=> {:local, 3}
  """

  import Bitwise

  @type direct ::
          {:global, non_neg_integer()} | {:bit, non_neg_integer()} | {:local, non_neg_integer()}
  @type t ::
          direct() | {:indexed, non_neg_integer(), {:imm, non_neg_integer()} | {:var, direct()}}

  @doc "Classifies a variable word that carries no `0x2000` index."
  @spec classify(non_neg_integer()) :: direct()
  def classify(word) when (word &&& 0xF000) == 0, do: {:global, word}
  def classify(word) when (word &&& 0x8000) != 0, do: {:bit, word &&& 0x7FFF}
  def classify(word) when (word &&& 0x4000) != 0, do: {:local, word &&& 0x0FFF}
  def classify(word), do: {:global, word &&& 0x0FFF}

  @doc """
  Reads a variable reference at `pos` in `code`: the word, and the index word when the
  first has `0x2000` set. Returns the reference and the position after it.
  """
  @spec read(binary(), non_neg_integer()) :: {t(), non_neg_integer()}
  def read(code, pos) do
    <<_::binary-size(^pos), word::little-16, _::binary>> = code
    indexed(word, code, pos + 2)
  end

  @doc "The variable a reference names, given how to read a direct variable's value."
  @spec resolve(t(), (direct() -> integer())) :: direct()
  def resolve({:indexed, base, {:imm, add}}, _read), do: classify(base + add)
  def resolve({:indexed, base, {:var, index}}, read), do: classify(base + read.(index))
  def resolve(direct, _read), do: direct

  defp indexed(word, code, pos) when (word &&& 0x2000) != 0 do
    <<_::binary-size(^pos), index::little-16, _::binary>> = code
    {{:indexed, word &&& bnot(0x2000) &&& 0xFFFF, index_of(index)}, pos + 2}
  end

  defp indexed(word, _code, pos), do: {classify(word), pos}

  defp index_of(index) when (index &&& 0x2000) != 0,
    do: {:var, classify(index &&& bnot(0x2000) &&& 0xFFFF)}

  defp index_of(index), do: {:imm, index &&& 0x0FFF}
end
