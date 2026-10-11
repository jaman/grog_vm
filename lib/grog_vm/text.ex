defmodule GrogVM.Text do
  @moduledoc """
  A message as a SCUMM v5 script holds it: bytes up to a NUL, with escape sequences
  introduced by `0xFF`.

  A decoded message is a list of parts:

    * a binary — characters as they are,
    * `:newline` (`0xFF 1`), `:keep` (`0xFF 2`, continue on the text already shown),
      `:wait` (`0xFF 3`, wait for the reader before going on), `{:code, 8}`,
    * `{:int, var}`, `{:verb, var}`, `{:name, var}` (`0xFF 4..6`) — a variable's value
      printed as a number, as the name of the verb it holds, or as the name of the
      object or actor it holds,
    * `{:string, number}` (`0xFF 7`) — string resource `number` (a constant, not a
      variable),
    * `{:anim, n}` (`9`), `{:color, n}` (`12`), `{:charset, n}` (`14`) and
      `{:code, code, n}` for other codes, each with its word argument,
    * `{:sound, bytes}` (`10`) with its fourteen bytes.

  Before a message reaches a host the variables are read, so `{:int, var}`,
  `{:verb, var}` and `{:name, var}` carry the value instead of the reference.
  """

  alias GrogVM.Var

  @type part ::
          binary()
          | :newline
          | :keep
          | :wait
          | {:code, byte()}
          | {:int | :verb | :name, Var.direct() | integer()}
          | {:string, non_neg_integer()}
          | {:anim | :color | :charset, non_neg_integer()}
          | {:code, byte(), non_neg_integer()}
          | {:sound, binary()}
  @type t :: [part()]

  @doc "Reads the message at `pos` in `code`; returns it and the position after its NUL."
  @spec read(binary(), non_neg_integer()) :: {t(), non_neg_integer()}
  def read(code, pos), do: read(code, pos, pos, [])

  @doc "The message's characters with every escape left out."
  @spec plain(t()) :: binary()
  def plain(message), do: for(part <- message, is_binary(part), into: <<>>, do: part)

  defp read(code, start, pos, acc) do
    <<_::binary-size(^pos), byte, _::binary>> = code
    at(byte, code, start, pos, acc)
  end

  defp at(0, code, start, pos, acc), do: {Enum.reverse(flush(code, start, pos, acc)), pos + 1}

  defp at(0xFF, code, start, pos, acc) do
    acc = flush(code, start, pos, acc)
    <<_::binary-size(^pos), 0xFF, escape, _::binary>> = code
    {part, next} = escape(escape, code, pos + 2)
    read(code, next, next, [part | acc])
  end

  defp at(_byte, code, start, pos, acc), do: read(code, start, pos + 1, acc)

  defp flush(_code, start, start, acc), do: acc
  defp flush(code, start, pos, acc), do: [binary_part(code, start, pos - start) | acc]

  defp escape(1, _code, pos), do: {:newline, pos}
  defp escape(2, _code, pos), do: {:keep, pos}
  defp escape(3, _code, pos), do: {:wait, pos}
  defp escape(8, _code, pos), do: {{:code, 8}, pos}

  defp escape(10, code, pos) do
    <<_::binary-size(^pos), bytes::binary-14, _::binary>> = code
    {{:sound, bytes}, pos + 14}
  end

  defp escape(escape, code, pos) do
    <<_::binary-size(^pos), word::little-16, _::binary>> = code
    {with_word(escape, word), pos + 2}
  end

  defp with_word(4, word), do: {:int, Var.classify(word)}
  defp with_word(5, word), do: {:verb, Var.classify(word)}
  defp with_word(6, word), do: {:name, Var.classify(word)}
  defp with_word(7, word), do: {:string, word}
  defp with_word(9, word), do: {:anim, word}
  defp with_word(12, word), do: {:color, word}
  defp with_word(14, word), do: {:charset, word}
  defp with_word(escape, word), do: {:code, escape, word}
end
