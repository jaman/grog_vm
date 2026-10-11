defmodule GrogVM.Runtime do
  @moduledoc """
  The functions compiled scripts call, and the steps they return.

  An instruction's code returns a step:

    * `{:cont, ctx}` — go on with the next instruction,
    * `{:pause, offset, ctx}` — the script waits for the next frame and continues at
      `offset`,
    * `{:stop, ctx}` — the script has ended, or was stopped while it ran,
    * `{:chain, number, args, ctx}` — the script ends and script `number` starts in its
      place.
  """

  import Bitwise

  alias GrogVM.{Ctx, Cutscene, Instruction, Machine, Scripts, Var}

  @type step ::
          {:cont, Ctx.t()}
          | {:pause, non_neg_integer(), Ctx.t()}
          | {:stop, Ctx.t()}
          | {:chain, non_neg_integer(), [integer()], Ctx.t()}

  @doc "A variable's value."
  @spec read(Ctx.t(), Var.t()) :: integer()
  def read(%Ctx{machine: machine}, {:global, number}), do: Machine.var(machine, number)
  def read(%Ctx{machine: machine}, {:bit, number}), do: Machine.bit(machine, number)

  def read(ctx, {:local, number}),
    do: ctx |> running_slot() |> Map.fetch!(:locals) |> elem(number)

  def read(ctx, {:indexed, _base, _index} = ref), do: read(ctx, resolve(ctx, ref))

  @doc "Sets a variable."
  @spec write(Ctx.t(), Var.t(), integer()) :: Ctx.t()
  def write(%Ctx{machine: machine} = ctx, {:global, number}, value),
    do: %{ctx | machine: Machine.put_var(machine, number, value)}

  def write(%Ctx{machine: machine} = ctx, {:bit, number}, value),
    do: %{ctx | machine: Machine.put_bit(machine, number, value)}

  def write(%Ctx{machine: machine, slot: index} = ctx, {:local, number}, value),
    do: %{
      ctx
      | machine:
          Machine.update_slot(machine, index, &%{&1 | locals: put_elem(&1.locals, number, value)})
    }

  def write(ctx, {:indexed, _base, _index} = ref, value), do: write(ctx, resolve(ctx, ref), value)

  @doc "A parameter's value: a constant as it is, a variable read."
  @spec value(Ctx.t(), Instruction.operand()) :: integer()
  def value(_ctx, {:imm, value}), do: value
  def value(ctx, {:var, ref}), do: read(ctx, ref)

  @doc """
  Parameters with every variable read, in the shape a host receives them (see
  `GrogVM.Host`).
  """
  @spec eval(Ctx.t(), term()) :: term()
  def eval(_ctx, {:imm, value}), do: value
  def eval(ctx, {:var, ref}), do: read(ctx, ref)
  def eval(ctx, list) when is_list(list), do: Enum.map(list, &eval(ctx, &1))

  def eval(ctx, {kind, {class, _number} = ref})
      when kind in [:int, :verb, :name] and class in [:global, :bit, :local],
      do: {kind, read(ctx, ref)}

  def eval(ctx, {name, args}) when is_atom(name) and is_list(args), do: {name, eval(ctx, args)}
  def eval(_ctx, other), do: other

  @doc "Counts one jump against the script's budget."
  @spec tick(Ctx.t()) :: Ctx.t()
  def tick(%Ctx{budget: 0, slot: index, machine: machine}),
    do:
      raise(
        "script in slot #{index} (#{inspect(Machine.slot(machine, index))}) ran without pausing"
      )

  def tick(%Ctx{budget: budget} = ctx), do: %{ctx | budget: budget - 1}

  @doc "Runs host operation `name` with `args`, storing a value into `result` when it has one."
  @spec host(Ctx.t(), non_neg_integer(), non_neg_integer(), atom(), [term()], Var.t() | nil) ::
          step()
  def host(%Ctx{host_module: host} = ctx, offset, next, name, args, result) do
    %{ctx | at: offset}
    |> host.op(List.to_tuple([name | eval(ctx, args)]))
    |> hosted(offset, next, result)
  end

  @doc "Runs host test `name`: `{true, ctx}` when it holds, `{false, ctx}` when not."
  @spec test(Ctx.t(), atom(), [term()]) :: {boolean(), Ctx.t()} | {:stop, Ctx.t()}
  def test(%Ctx{host_module: host} = ctx, name, args) do
    {:ok, holds, ctx} = host.op(ctx, List.to_tuple([name | eval(ctx, args)]))
    if alive?(ctx), do: {holds == true, ctx}, else: {:stop, ctx}
  end

  @doc "Ends the running script."
  @spec stop_object_code(Ctx.t()) :: step()
  def stop_object_code(%Ctx{machine: machine, slot: index} = ctx),
    do: {:stop, %{ctx | machine: Machine.drop_slot(machine, index)}}

  @doc "Pauses the running script for `jiffies`, continuing at `next`."
  @spec delay(Ctx.t(), non_neg_integer(), integer()) :: step()
  def delay(%Ctx{machine: machine, slot: index} = ctx, next, jiffies) do
    machine = Machine.update_slot(machine, index, &%{&1 | status: :paused, delay: jiffies})
    {:pause, next, %{ctx | machine: machine}}
  end

  @doc "A random number from 0 to `max`, both included."
  @spec random(Ctx.t(), non_neg_integer()) :: {non_neg_integer(), Ctx.t()}
  def random(%Ctx{machine: machine} = ctx, max) do
    {value, machine} = Machine.random(machine, max)
    {value, %{ctx | machine: machine}}
  end

  @doc "1 when a global or local script numbered `number` is running, otherwise 0."
  @spec script_running(Ctx.t(), non_neg_integer()) :: 0 | 1
  def script_running(%Ctx{machine: machine}, number),
    do: if(Machine.running?(machine, number), do: 1, else: 0)

  @doc "Integer division, truncating toward zero."
  @spec divide(integer(), integer()) :: integer()
  def divide(_dividend, 0), do: raise(ArithmeticError, "script divided by zero")
  def divide(dividend, divisor), do: div(dividend, divisor)

  @doc "Bitwise and."
  @spec bit_and(integer(), integer()) :: integer()
  def bit_and(left, right), do: left &&& right

  @doc "Bitwise or."
  @spec bit_or(integer(), integer()) :: integer()
  def bit_or(left, right), do: left ||| right

  @doc "Stores `values` into `result` and the variables numbered after it."
  @spec write_range(Ctx.t(), Var.t(), [integer()]) :: Ctx.t()
  def write_range(ctx, result, values) do
    {kind, first} = resolve(ctx, result)

    values
    |> Enum.with_index(first)
    |> Enum.reduce(ctx, fn {value, number}, acc -> write(acc, {kind, number}, value) end)
  end

  @doc "Starts script `number` and runs it until it first pauses."
  @spec start_script(Ctx.t(), non_neg_integer(), [integer()], map()) :: step()
  def start_script(ctx, number, args, flags) do
    ctx
    |> Scripts.start(number, args,
      recursive: flags.recursive,
      freeze_resistant: flags.freeze_resistant
    )
    |> continue()
  end

  @doc "Starts `object`'s code for `verb` and runs it until it first pauses."
  @spec start_object(Ctx.t(), non_neg_integer(), non_neg_integer(), [integer()]) :: step()
  def start_object(ctx, object, verb, args),
    do: ctx |> Scripts.start_object(object, verb, args, []) |> continue()

  @doc "Stops every script numbered `number`; 0 ends the running one."
  @spec stop_script(Ctx.t(), non_neg_integer()) :: step()
  def stop_script(ctx, 0), do: stop_object_code(ctx)
  def stop_script(ctx, number), do: ctx |> Scripts.stop(number) |> continue()

  @doc "Stops every script of `object`."
  @spec stop_object_script(Ctx.t(), non_neg_integer()) :: step()
  def stop_object_script(ctx, object), do: ctx |> Scripts.stop_object(object) |> continue()

  @doc "Freezes other scripts with a non-zero `flag`; 0 takes one freeze off."
  @spec freeze(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def freeze(%Ctx{machine: machine} = ctx, 0), do: %{ctx | machine: Machine.unfreeze(machine)}

  def freeze(%Ctx{machine: machine, slot: index} = ctx, flag),
    do: %{ctx | machine: Machine.freeze(machine, index, flag)}

  @doc "Opens a cutscene with `args`, running the cutscene start script."
  @spec cutscene(Ctx.t(), [integer()]) :: step()
  def cutscene(ctx, args), do: ctx |> Cutscene.open(args) |> continue()

  @doc "Closes the innermost cutscene, running the cutscene end script."
  @spec end_cutscene(Ctx.t()) :: step()
  def end_cutscene(ctx), do: ctx |> Cutscene.close() |> continue()

  @doc "Marks where a skipped cutscene resumes the running script."
  @spec begin_override(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def begin_override(ctx, abort_at), do: Cutscene.begin_override(ctx, abort_at)

  @doc "Clears the innermost cutscene's resume point."
  @spec end_override(Ctx.t()) :: Ctx.t()
  def end_override(ctx), do: Cutscene.end_override(ctx)

  @doc "Evaluates an `expression` instruction's steps and stores the result."
  @spec expression(Ctx.t(), Var.t(), [term()]) :: step()
  def expression(ctx, result, steps) do
    {[value], ctx} = Enum.reduce(steps, {[], ctx}, &expression_step/2)
    continue(write(ctx, result, value))
  end

  @doc "Whether the script `ctx` names is still the one that started this run."
  @spec alive?(Ctx.t()) :: boolean()
  def alive?(%Ctx{machine: machine, slot: index, slot_id: id}),
    do: match?(%{id: ^id}, Machine.slot(machine, index))

  @doc "`{:cont, ctx}` while the running script is alive, `{:stop, ctx}` once stopped."
  @spec continue(Ctx.t()) :: step()
  def continue(ctx), do: if(alive?(ctx), do: {:cont, ctx}, else: {:stop, ctx})

  defp hosted({:ok, ctx}, _offset, _next, _result), do: continue(ctx)

  defp hosted({:ok, value, ctx}, _offset, _next, result) when not is_nil(result) do
    case alive?(ctx) do
      true -> {:cont, write(ctx, result, integer(value))}
      false -> {:stop, ctx}
    end
  end

  defp hosted({:pause, ctx}, _offset, next, _result), do: pause(ctx, next)
  defp hosted({:retry, ctx}, offset, _next, _result), do: pause(ctx, offset)

  defp pause(ctx, at), do: if(alive?(ctx), do: {:pause, at, ctx}, else: {:stop, ctx})

  defp integer(true), do: 1
  defp integer(false), do: 0
  defp integer(value) when is_integer(value), do: value

  defp expression_step({:push, operand}, {stack, ctx}), do: {[value(ctx, operand) | stack], ctx}
  defp expression_step(:add, {[right, left | stack], ctx}), do: {[left + right | stack], ctx}
  defp expression_step(:subtract, {[right, left | stack], ctx}), do: {[left - right | stack], ctx}
  defp expression_step(:multiply, {[right, left | stack], ctx}), do: {[left * right | stack], ctx}

  defp expression_step(:divide, {[right, left | stack], ctx}),
    do: {[divide(left, right) | stack], ctx}

  defp expression_step({:op, instruction}, {stack, ctx}) do
    ctx = nested(ctx, instruction)
    {[read(ctx, {:global, 0}) | stack], ctx}
  end

  defp nested(ctx, %Instruction{op: :get_random_nr, args: [max], result: result}) do
    {number, ctx} = random(ctx, value(ctx, max))
    write(ctx, result, number)
  end

  defp nested(ctx, %Instruction{op: :is_script_running, args: [number], result: result}),
    do: write(ctx, result, script_running(ctx, value(ctx, number)))

  defp nested(%Ctx{host_module: host} = ctx, %Instruction{op: name, args: args, result: result}) do
    {:ok, value, ctx} = host.op(ctx, List.to_tuple([name | eval(ctx, args)]))
    write(ctx, result, integer(value))
  end

  defp running_slot(%Ctx{machine: machine, slot: index}), do: Machine.slot(machine, index)

  defp resolve(ctx, ref), do: Var.resolve(ref, &read(ctx, &1))
end
