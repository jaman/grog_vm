defmodule GrogVM.Machine do
  @moduledoc """
  The state scripts share: global and bit variables, the script slots, the cutscene
  stack, sentence freezing and the random number state.

  Every function is pure and returns the new machine. Slots are kept by index; a new
  script takes the lowest free index, and scripts run in index order each frame.

  The cutscene stack starts with one base level. Each level holds the argument the
  cutscene was opened with, and, while an override is open, the slot and offset a skip
  resumes at.
  """

  alias GrogVM.Slot

  @slots 40

  @enforce_keys [:config]
  defstruct [
    :config,
    vars: %{},
    bits: MapSet.new(),
    slots: %{},
    next_id: 1,
    cutscenes: [%{data: 0, slot: nil, abort_at: nil}],
    cutscene_slot: nil,
    sentence_freeze: 0,
    random: nil
  ]

  @typedoc """
  The variable numbers the machine itself reads and writes: `:override`,
  `:cutscene_start_script`, `:cutscene_end_script`.
  """
  @type config :: %{
          override: non_neg_integer(),
          cutscene_start_script: non_neg_integer(),
          cutscene_end_script: non_neg_integer()
        }
  @type level :: %{
          data: integer(),
          slot: non_neg_integer() | nil,
          abort_at: non_neg_integer() | nil
        }
  @type t :: %__MODULE__{
          config: config(),
          vars: %{non_neg_integer() => integer()},
          bits: MapSet.t(non_neg_integer()),
          slots: %{non_neg_integer() => Slot.t()},
          next_id: pos_integer(),
          cutscenes: [level()],
          cutscene_slot: non_neg_integer() | nil,
          sentence_freeze: non_neg_integer(),
          random: :rand.state()
        }

  @doc """
  A machine with no scripts and every variable zero. Options: `:config` (see
  `t:config/0`, defaults are SCUMM v5's 5, 35 and 36) and `:seed`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config =
      Map.merge(
        %{override: 5, cutscene_start_script: 35, cutscene_end_script: 36},
        Map.new(Keyword.get(opts, :config, %{}))
      )

    %__MODULE__{config: config, random: :rand.seed_s(:exsss, Keyword.get(opts, :seed, 1))}
  end

  @doc "A global variable's value."
  @spec var(t(), non_neg_integer()) :: integer()
  def var(%__MODULE__{vars: vars}, number), do: Map.get(vars, number, 0)

  @doc "Sets a global variable."
  @spec put_var(t(), non_neg_integer(), integer()) :: t()
  def put_var(%__MODULE__{vars: vars} = machine, number, value),
    do: %{machine | vars: Map.put(vars, number, value)}

  @doc "A bit variable's value, 0 or 1."
  @spec bit(t(), non_neg_integer()) :: 0 | 1
  def bit(%__MODULE__{bits: bits}, number), do: if(MapSet.member?(bits, number), do: 1, else: 0)

  @doc "Sets a bit variable: any value but 0 sets it."
  @spec put_bit(t(), non_neg_integer(), integer()) :: t()
  def put_bit(%__MODULE__{bits: bits} = machine, number, 0),
    do: %{machine | bits: MapSet.delete(bits, number)}

  def put_bit(%__MODULE__{bits: bits} = machine, number, _value),
    do: %{machine | bits: MapSet.put(bits, number)}

  @doc "A random integer from 0 to `max`, both included."
  @spec random(t(), non_neg_integer()) :: {non_neg_integer(), t()}
  def random(%__MODULE__{random: state} = machine, max) do
    {value, state} = :rand.uniform_s(max + 1, state)
    {value - 1, %{machine | random: state}}
  end

  @doc "The slot at `index`, or `nil`."
  @spec slot(t(), non_neg_integer()) :: Slot.t() | nil
  def slot(%__MODULE__{slots: slots}, index), do: Map.get(slots, index)

  @doc "Replaces the slot at `index`."
  @spec put_slot(t(), non_neg_integer(), Slot.t()) :: t()
  def put_slot(%__MODULE__{slots: slots} = machine, index, slot),
    do: %{machine | slots: Map.put(slots, index, slot)}

  @doc "Changes the slot at `index` with `fun`, when there is one."
  @spec update_slot(t(), non_neg_integer(), (Slot.t() -> Slot.t())) :: t()
  def update_slot(%__MODULE__{slots: slots} = machine, index, fun) when is_map_key(slots, index),
    do: %{machine | slots: Map.update!(slots, index, fun)}

  def update_slot(machine, _index, _fun), do: machine

  @doc "Ends the script at `index`."
  @spec drop_slot(t(), non_neg_integer()) :: t()
  def drop_slot(%__MODULE__{slots: slots} = machine, index),
    do: %{machine | slots: Map.delete(slots, index)}

  @doc """
  Puts a new script in the lowest free slot. `slot` holds everything but its `id`.
  Returns the index, or `:error` when every slot is taken.
  """
  @spec add_slot(t(), map()) :: {:ok, non_neg_integer(), t()} | :error
  def add_slot(%__MODULE__{slots: slots, next_id: id} = machine, fields) do
    case Enum.find(0..(@slots - 1), &(not is_map_key(slots, &1))) do
      nil ->
        :error

      index ->
        {:ok, index,
         %{put_slot(machine, index, struct!(Slot, Map.put(fields, :id, id))) | next_id: id + 1}}
    end
  end

  @doc "The indexes of the slots `keep?` selects, in order."
  @spec indexes(t(), (Slot.t() -> boolean())) :: [non_neg_integer()]
  def indexes(%__MODULE__{slots: slots}, keep?) do
    for {index, slot} <- Enum.sort(slots), keep?.(slot), do: index
  end

  @doc "Ends every script `stop?` selects."
  @spec stop_where(t(), (Slot.t() -> boolean())) :: t()
  def stop_where(machine, stop?),
    do: machine |> indexes(stop?) |> Enum.reduce(machine, &drop_slot(&2, &1))

  @doc "Whether a global or local script numbered `number` is running."
  @spec running?(t(), non_neg_integer()) :: boolean()
  def running?(%__MODULE__{slots: slots}, number),
    do:
      Enum.any?(slots, fn {_index, slot} ->
        slot.number == number and slot.kind in [:global, :local]
      end)

  @doc """
  Freezes every script but the one at `current`: those started freeze-resistant only
  when `flag` is `0x80` or more. Sentences freeze too. The script that opened the
  cutscene being started is never frozen.
  """
  @spec freeze(t(), non_neg_integer() | nil, pos_integer()) :: t()
  def freeze(%__MODULE__{} = machine, current, flag) do
    machine
    |> indexes(&(not &1.freeze_resistant or flag >= 0x80))
    |> Enum.reject(&(&1 == current))
    |> Enum.reduce(machine, fn index, acc ->
      update_slot(acc, index, &%{&1 | frozen: &1.frozen + 1})
    end)
    |> Map.update!(:sentence_freeze, &(&1 + 1))
    |> thaw_cutscene_slot()
  end

  @doc "Takes one freeze off every frozen script and off sentences."
  @spec unfreeze(t()) :: t()
  def unfreeze(%__MODULE__{} = machine) do
    machine
    |> indexes(&(&1.frozen > 0))
    |> Enum.reduce(machine, fn index, acc ->
      update_slot(acc, index, &%{&1 | frozen: &1.frozen - 1})
    end)
    |> Map.update!(:sentence_freeze, &max(&1 - 1, 0))
    |> thaw_cutscene_slot()
  end

  @doc "Counts `jiffies` off every paused script's delay; those that reach zero run again."
  @spec decrease_delays(t(), non_neg_integer()) :: t()
  def decrease_delays(%__MODULE__{slots: slots} = machine, jiffies) do
    %{machine | slots: Map.new(slots, fn {index, slot} -> {index, count_down(slot, jiffies)} end)}
  end

  defp count_down(%Slot{status: :paused, delay: delay} = slot, jiffies) when delay - jiffies <= 0,
    do: %{slot | status: :running, delay: 0}

  defp count_down(%Slot{status: :paused, delay: delay} = slot, jiffies),
    do: %{slot | delay: delay - jiffies}

  defp count_down(slot, _jiffies), do: slot

  defp thaw_cutscene_slot(%__MODULE__{cutscene_slot: nil} = machine), do: machine

  defp thaw_cutscene_slot(%__MODULE__{cutscene_slot: index} = machine),
    do: update_slot(machine, index, &%{&1 | frozen: 0})
end
