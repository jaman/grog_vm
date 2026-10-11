defmodule GrogVM.Slot do
  @moduledoc """
  One running script.

    * `id` — unique for the life of the machine, so a script can tell whether it was
      stopped and its slot reused while it waited on a nested call,
    * `number` — the script number, or the object's number for an object script,
    * `kind` — `:global` (numbers below 200), `:local` (the room's, 200 and up),
      `:room` (an entry or exit script), `:object` (a room object's verb) or
      `:inventory` (the verb of an object being carried),
    * `code` — the compiled module, `entry` — the offset it started at, `offset` —
      where it continues,
    * `status` — `:running` or `:paused` (waiting out `delay` jiffies),
    * `frozen` — how many freezes hold it; a frozen script does not run,
    * `freeze_resistant`, `recursive` — as it was started,
    * `cutscene_override` — how many cutscenes it has open,
    * `locals` — its 25 local variables.
  """

  @locals 25

  @enforce_keys [:id, :number, :kind, :code, :offset]
  defstruct [
    :id,
    :number,
    :kind,
    :code,
    :offset,
    entry: 0,
    status: :running,
    frozen: 0,
    freeze_resistant: false,
    recursive: false,
    delay: 0,
    cutscene_override: 0,
    locals: Tuple.duplicate(0, @locals)
  ]

  @type kind :: :global | :local | :room | :object | :inventory
  @type t :: %__MODULE__{
          id: pos_integer(),
          number: non_neg_integer(),
          kind: kind(),
          code: module(),
          entry: non_neg_integer(),
          offset: non_neg_integer(),
          status: :running | :paused,
          frozen: non_neg_integer(),
          freeze_resistant: boolean(),
          recursive: boolean(),
          delay: integer(),
          cutscene_override: non_neg_integer(),
          locals: tuple()
        }

  @doc "Locals holding `args` in order, the rest zero."
  @spec locals([integer()]) :: tuple()
  def locals(args) do
    args
    |> Enum.take(@locals)
    |> Kernel.++(List.duplicate(0, @locals - min(length(args), @locals)))
    |> List.to_tuple()
  end

  @doc "Whether the slot runs this frame."
  @spec runnable?(t()) :: boolean()
  def runnable?(%__MODULE__{status: :running, frozen: 0}), do: true
  def runnable?(%__MODULE__{}), do: false
end
