defmodule GrogVM do
  @moduledoc """
  Runs SCUMM v5 scripts compiled to Elixir against a game that implements
  `GrogVM.Host`.

      ctx = GrogVM.new(MyGame.Host, host_state)
      ctx = GrogVM.start_script(ctx, 1, [])
      ctx = GrogVM.run_frame(ctx, 6)

  The game owns the main loop: each SCUMM frame it counts the elapsed jiffies off
  waiting scripts and runs the scripts due (`run_frame/2`), and between frames it starts
  scripts for input, rooms and sentences. Code is compiled with `GrogVM.Compiler`;
  `c:GrogVM.Host.code/2` hands the machine the compiled module a script number or object
  verb starts.
  """

  alias GrogVM.{Ctx, Cutscene, Machine, Runtime, Scripts, Slot}

  @doc "A context with a fresh machine. Options go to `GrogVM.Machine.new/1`."
  @spec new(module(), term(), keyword()) :: Ctx.t()
  def new(host_module, host, opts \\ []), do: Ctx.new(host_module, host, Machine.new(opts))

  @doc "Counts `jiffies` off waiting scripts, then runs every script due this frame."
  @spec run_frame(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def run_frame(%Ctx{machine: machine} = ctx, jiffies),
    do: Scripts.run_frame(%{ctx | machine: Machine.decrease_delays(machine, jiffies)})

  @doc "Starts global or local script `number`; see `GrogVM.Scripts.start/4`."
  @spec start_script(Ctx.t(), non_neg_integer(), [integer()], Scripts.opts()) :: Ctx.t()
  def start_script(ctx, number, args, opts \\ []), do: Scripts.start(ctx, number, args, opts)

  @doc "Starts `object`'s code for `verb`; see `GrogVM.Scripts.start_object/5`."
  @spec start_object(Ctx.t(), non_neg_integer(), non_neg_integer(), [integer()], Scripts.opts()) ::
          Ctx.t()
  def start_object(ctx, object, verb, args, opts \\ []),
    do: Scripts.start_object(ctx, object, verb, args, opts)

  @doc "Starts code the host found itself, such as a room's entry script."
  @spec start_code(Ctx.t(), GrogVM.Host.code(), non_neg_integer(), [integer()], Scripts.opts()) ::
          Ctx.t()
  def start_code(ctx, code, number, args, opts \\ []),
    do: Scripts.start_code(ctx, code, number, args, opts)

  @doc "Stops every global and local script numbered `number`."
  @spec stop_script(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def stop_script(ctx, number), do: Scripts.stop(ctx, number)

  @doc "Stops every script `stop?` selects, such as a room's local scripts when it is left."
  @spec stop_where(Ctx.t(), (Slot.t() -> boolean())) :: Ctx.t()
  def stop_where(%Ctx{machine: machine} = ctx, stop?),
    do: %{ctx | machine: Machine.stop_where(machine, stop?)}

  @doc "Whether a global or local script numbered `number` is running."
  @spec running?(Ctx.t(), non_neg_integer()) :: boolean()
  def running?(%Ctx{machine: machine}, number), do: Machine.running?(machine, number)

  @doc "Every script running or waiting, in slot order."
  @spec scripts(Ctx.t()) :: [Slot.t()]
  def scripts(%Ctx{machine: machine}),
    do: for({_index, slot} <- Enum.sort(machine.slots), do: slot)

  @doc "A global variable's value."
  @spec var(Ctx.t(), non_neg_integer()) :: integer()
  def var(%Ctx{machine: machine}, number), do: Machine.var(machine, number)

  @doc "Sets a global variable."
  @spec put_var(Ctx.t(), non_neg_integer(), integer()) :: Ctx.t()
  def put_var(%Ctx{machine: machine} = ctx, number, value),
    do: %{ctx | machine: Machine.put_var(machine, number, value)}

  @doc "Reads any variable reference, including the running script's locals."
  @spec read(Ctx.t(), GrogVM.Var.t()) :: integer()
  def read(ctx, ref), do: Runtime.read(ctx, ref)

  @doc "Skips the innermost cutscene when it can be skipped."
  @spec abort_cutscene(Ctx.t()) :: Ctx.t()
  def abort_cutscene(%Ctx{machine: machine} = ctx), do: %{ctx | machine: Cutscene.abort(machine)}

  @doc "The script running now, or `nil` between scripts."
  @spec current(Ctx.t()) :: Slot.t() | nil
  def current(%Ctx{slot: nil}), do: nil
  def current(%Ctx{machine: machine, slot: index}), do: Machine.slot(machine, index)

  @doc "Whether sentences are frozen (by `freeze_scripts`)."
  @spec sentences_frozen?(Ctx.t()) :: boolean()
  def sentences_frozen?(%Ctx{machine: %Machine{sentence_freeze: count}}), do: count > 0
end
