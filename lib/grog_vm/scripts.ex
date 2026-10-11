defmodule GrogVM.Scripts do
  @moduledoc """
  Starting, stopping and running scripts.

  A started script runs at once, inside whatever started it, until it first pauses or
  ends; then its starter goes on. Each frame, `run_frame/1` runs every script that may
  run and has not run yet this frame, in slot order.
  """

  alias GrogVM.{Ctx, Machine, Slot}

  @max_depth 15

  @type opts :: [recursive: boolean(), freeze_resistant: boolean()]

  @doc """
  Starts script `number` with `args` as its first locals. Unless `recursive: true`, any
  running copy is stopped first.
  """
  @spec start(Ctx.t(), non_neg_integer(), [integer()], opts()) :: Ctx.t()
  def start(ctx, 0, _args, _opts), do: ctx

  def start(%Ctx{host_module: host} = ctx, number, args, opts) do
    ctx = if Keyword.get(opts, :recursive, false), do: ctx, else: stop(ctx, number)
    ctx |> host.code({:script, number}) |> launch(ctx, number, args, opts, {:script, number})
  end

  @doc """
  Starts `object`'s code for `verb`. Unless `recursive: true`, the object's running
  scripts are stopped first. An object with no code for the verb starts nothing.
  """
  @spec start_object(Ctx.t(), non_neg_integer(), non_neg_integer(), [integer()], opts()) ::
          Ctx.t()
  def start_object(ctx, 0, _verb, _args, _opts), do: ctx

  def start_object(%Ctx{host_module: host} = ctx, object, verb, args, opts) do
    ctx = if Keyword.get(opts, :recursive, false), do: ctx, else: stop_object(ctx, object)

    case host.code(ctx, {:object, object, verb}) do
      :none -> ctx
      found -> launch(found, ctx, object, args, opts, {:object, object, verb})
    end
  end

  @doc "Starts code the host found itself (an entry or exit script, say) as script `number`."
  @spec start_code(Ctx.t(), GrogVM.Host.code(), non_neg_integer(), [integer()], opts()) :: Ctx.t()
  def start_code(ctx, code, number, args, opts),
    do: launch({:ok, code}, ctx, number, args, opts, code)

  @doc "Stops every global and local script numbered `number`."
  @spec stop(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def stop(%Ctx{machine: machine} = ctx, number),
    do: %{
      ctx
      | machine:
          Machine.stop_where(machine, &(&1.number == number and &1.kind in [:global, :local]))
    }

  @doc "Stops every script of `object`."
  @spec stop_object(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def stop_object(ctx, 0), do: ctx

  def stop_object(%Ctx{machine: machine} = ctx, object),
    do: %{
      ctx
      | machine:
          Machine.stop_where(machine, &(&1.number == object and &1.kind in [:object, :inventory]))
    }

  @doc "Runs every script that may run this frame."
  @spec run_frame(Ctx.t()) :: Ctx.t()
  def run_frame(%Ctx{machine: machine} = ctx) do
    machine
    |> Machine.indexes(fn _slot -> true end)
    |> Enum.reduce(%{ctx | ran: MapSet.new()}, &run_if_due/2)
  end

  @doc "Runs the script at `index` until it pauses or ends, then returns to the caller."
  @spec run(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def run(%Ctx{depth: depth}, _index) when depth >= @max_depth,
    do: raise("scripts nested more than #{@max_depth} deep")

  def run(%Ctx{} = ctx, index) do
    %Slot{id: id, code: code, offset: offset} = Machine.slot(ctx.machine, index)

    inner = %{
      ctx
      | slot: index,
        slot_id: id,
        depth: ctx.depth + 1,
        ran: MapSet.put(ctx.ran, id),
        budget: Ctx.budget()
    }

    finished = offset |> code.run(inner) |> settle()
    %{finished | slot: ctx.slot, slot_id: ctx.slot_id, depth: ctx.depth, budget: ctx.budget}
  end

  defp run_if_due(index, %Ctx{machine: machine, ran: ran} = ctx) do
    case Machine.slot(machine, index) do
      %Slot{id: id} = slot ->
        if Slot.runnable?(slot) and not MapSet.member?(ran, id), do: run(ctx, index), else: ctx

      nil ->
        ctx
    end
  end

  defp launch(:none, _ctx, _number, _args, _opts, wanted),
    do: raise(ArgumentError, "no code for #{inspect(wanted)}")

  defp launch({:ok, code}, %Ctx{machine: machine} = ctx, number, args, opts, wanted) do
    fields = %{
      number: number,
      kind: code.kind,
      code: code.code,
      offset: code.offset,
      entry: code.offset,
      freeze_resistant: Keyword.get(opts, :freeze_resistant, false),
      recursive: Keyword.get(opts, :recursive, false),
      locals: Slot.locals(args)
    }

    case Machine.add_slot(machine, fields) do
      {:ok, index, machine} -> run(%{ctx | machine: machine}, index)
      :error -> raise("no free script slot for #{inspect(wanted)}")
    end
  end

  defp settle({:pause, offset, ctx}),
    do: on_own_slot(ctx, &Machine.update_slot(&1, &2, fn slot -> %{slot | offset: offset} end))

  defp settle({:stop, ctx}), do: on_own_slot(ctx, &Machine.drop_slot/2)

  defp settle({:chain, number, args, %Ctx{machine: machine, slot: index} = ctx}) do
    freeze_resistant = machine |> Machine.slot(index) |> Map.fetch!(:freeze_resistant)

    start(%{ctx | machine: Machine.drop_slot(machine, index)}, number, args,
      freeze_resistant: freeze_resistant
    )
  end

  defp on_own_slot(%Ctx{machine: machine, slot: index, slot_id: id} = ctx, change) do
    case Machine.slot(machine, index) do
      %Slot{id: ^id} -> %{ctx | machine: change.(machine, index)}
      _gone -> ctx
    end
  end
end
