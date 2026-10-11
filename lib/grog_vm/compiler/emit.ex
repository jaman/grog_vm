defmodule GrogVM.Compiler.Emit do
  @moduledoc """
  The Elixir code of one decoded program: a function per instruction that does its work
  and calls the next instruction's function directly, and `run/2`, which starts at any
  instruction by its offset.
  """

  alias GrogVM.Instruction

  @runtime GrogVM.Runtime
  @compare %{
    is_equal: :==,
    is_not_equal: :!=,
    is_greater: :>,
    is_greater_equal: :>=,
    is_less: :<,
    is_less_equal: :<=
  }
  @arithmetic %{add: :+, subtract: :-, multiply: :*}
  @tests [:if_state, :if_not_state, :is_actor_in_box, :if_class_of_is]

  @doc "The quoted module `name` for `program`."
  @spec module(module(), GrogVM.Decode.program()) :: Macro.t()
  def module(name, program) do
    instructions = program |> Map.values() |> Enum.sort_by(& &1.offset)
    runs = Enum.map(instructions, &run_clause/1)
    steps = Enum.map(instructions, &step/1)

    quote do
      defmodule unquote(name) do
        @moduledoc false
        unquote_splicing(runs)
        unquote_splicing(steps)
      end
    end
  end

  defp ctx, do: Macro.var(:ctx, __MODULE__)

  defp fname(offset), do: :"i#{offset}"

  defp call(offset, ctx_expr), do: {fname(offset), [], [ctx_expr]}

  defp run_clause(%Instruction{offset: offset}) do
    quote do
      def run(unquote(offset), unquote(ctx())), do: unquote(call(offset, ctx()))
    end
  end

  defp step(%Instruction{offset: offset} = instruction) do
    quote do
      defp unquote(fname(offset))(unquote(ctx())), do: unquote(body(instruction))
    end
  end

  defp value({:imm, value}), do: value

  defp value({:var, ref}),
    do: quote(do: unquote(@runtime).read(unquote(ctx()), unquote(Macro.escape(ref))))

  defp read(ref), do: value({:var, ref})

  defp write(ref, expr),
    do:
      quote(
        do: unquote(@runtime).write(unquote(ctx()), unquote(Macro.escape(ref)), unquote(expr))
      )

  defp next(%Instruction{next: next}, ctx_expr), do: call(next, ctx_expr)

  defp jump(target), do: call(target, quote(do: unquote(@runtime).tick(unquote(ctx()))))

  defp continuing(step_expr, instruction) do
    quote do
      case unquote(step_expr) do
        {:cont, unquote(ctx())} -> unquote(next(instruction, ctx()))
        done -> done
      end
    end
  end

  defp body(%Instruction{op: :stop_object_code}),
    do: quote(do: unquote(@runtime).stop_object_code(unquote(ctx())))

  defp body(%Instruction{op: :break_here, next: next}),
    do: quote(do: {:pause, unquote(next), unquote(ctx())})

  defp body(%Instruction{op: :jump_relative, target: target}), do: jump(target)

  defp body(%Instruction{op: op} = instruction) when is_map_key(@compare, op),
    do: compare(instruction)

  defp body(%Instruction{op: op} = instruction) when op in [:equal_zero, :not_equal_zero],
    do: zero(instruction)

  defp body(%Instruction{op: op} = instruction) when op in @tests, do: test(instruction)

  defp body(%Instruction{op: op} = instruction) when is_map_key(@arithmetic, op),
    do: arithmetic(instruction)

  defp body(%Instruction{} = instruction), do: other(instruction)

  defp compare(%Instruction{op: op, args: [{:var, ref}, operand], target: target} = instruction) do
    condition = {Map.fetch!(@compare, op), [], [value(operand), read(ref)]}

    quote do
      if unquote(condition), do: unquote(next(instruction, ctx())), else: unquote(jump(target))
    end
  end

  defp zero(%Instruction{op: op, args: [{:var, ref}], target: target} = instruction) do
    condition =
      if op == :equal_zero,
        do: quote(do: unquote(read(ref)) == 0),
        else: quote(do: unquote(read(ref)) != 0)

    quote do
      if unquote(condition), do: unquote(next(instruction, ctx())), else: unquote(jump(target))
    end
  end

  defp test(%Instruction{op: op, args: args, target: target} = instruction) do
    quote do
      case unquote(@runtime).test(unquote(ctx()), unquote(op), unquote(Macro.escape(args))) do
        {true, unquote(ctx())} -> unquote(next(instruction, ctx()))
        {false, unquote(ctx())} -> unquote(jump(target))
        done -> done
      end
    end
  end

  defp arithmetic(%Instruction{op: op, args: [operand], result: result} = instruction) do
    sum = {Map.fetch!(@arithmetic, op), [], [read(result), value(operand)]}
    next(instruction, write(result, sum))
  end

  defp other(%Instruction{op: :move, args: [operand], result: result} = instruction),
    do: next(instruction, write(result, value(operand)))

  defp other(%Instruction{op: :divide, args: [operand], result: result} = instruction),
    do:
      next(
        instruction,
        write(
          result,
          quote(do: unquote(@runtime).divide(unquote(read(result)), unquote(value(operand))))
        )
      )

  defp other(%Instruction{op: :and, args: [operand], result: result} = instruction),
    do:
      next(
        instruction,
        write(
          result,
          quote(do: unquote(@runtime).bit_and(unquote(read(result)), unquote(value(operand))))
        )
      )

  defp other(%Instruction{op: :or, args: [operand], result: result} = instruction),
    do:
      next(
        instruction,
        write(
          result,
          quote(do: unquote(@runtime).bit_or(unquote(read(result)), unquote(value(operand))))
        )
      )

  defp other(%Instruction{op: :increment, result: result} = instruction),
    do: next(instruction, write(result, quote(do: unquote(read(result)) + 1)))

  defp other(%Instruction{op: :decrement, result: result} = instruction),
    do: next(instruction, write(result, quote(do: unquote(read(result)) - 1)))

  defp other(%Instruction{op: :set_var_range, args: [values], result: result} = instruction) do
    values = Enum.map(values, &value/1)

    next(
      instruction,
      quote(
        do:
          unquote(@runtime).write_range(
            unquote(ctx()),
            unquote(Macro.escape(result)),
            unquote(values)
          )
      )
    )
  end

  defp other(%Instruction{op: :get_random_nr, args: [max], result: result} = instruction) do
    quote do
      {number, unquote(ctx())} = unquote(@runtime).random(unquote(ctx()), unquote(value(max)))
      unquote(next(instruction, write(result, quote(do: number))))
    end
  end

  defp other(%Instruction{op: :is_script_running, args: [number], result: result} = instruction),
    do:
      next(
        instruction,
        write(
          result,
          quote(do: unquote(@runtime).script_running(unquote(ctx()), unquote(value(number))))
        )
      )

  defp other(%Instruction{op: :delay, args: [jiffies], next: next}),
    do: quote(do: unquote(@runtime).delay(unquote(ctx()), unquote(next), unquote(value(jiffies))))

  defp other(%Instruction{op: :delay_variable, args: [{:var, ref}], next: next}),
    do: quote(do: unquote(@runtime).delay(unquote(ctx()), unquote(next), unquote(read(ref))))

  defp other(%Instruction{op: :start_script, args: [number, args, flags]} = instruction) do
    continuing(
      quote(
        do:
          unquote(@runtime).start_script(
            unquote(ctx()),
            unquote(value(number)),
            unquote(Enum.map(args, &value/1)),
            unquote(Macro.escape(flags))
          )
      ),
      instruction
    )
  end

  defp other(%Instruction{op: :chain_script, args: [number, args]}),
    do:
      quote(
        do: {:chain, unquote(value(number)), unquote(Enum.map(args, &value/1)), unquote(ctx())}
      )

  defp other(%Instruction{op: :start_object, args: [object, verb, args]} = instruction) do
    continuing(
      quote(
        do:
          unquote(@runtime).start_object(
            unquote(ctx()),
            unquote(value(object)),
            unquote(value(verb)),
            unquote(Enum.map(args, &value/1))
          )
      ),
      instruction
    )
  end

  defp other(%Instruction{op: :stop_script, args: [number]} = instruction),
    do:
      continuing(
        quote(do: unquote(@runtime).stop_script(unquote(ctx()), unquote(value(number)))),
        instruction
      )

  defp other(%Instruction{op: :stop_object_script, args: [object]} = instruction),
    do:
      continuing(
        quote(do: unquote(@runtime).stop_object_script(unquote(ctx()), unquote(value(object)))),
        instruction
      )

  defp other(%Instruction{op: :freeze_scripts, args: [flag]} = instruction),
    do:
      next(instruction, quote(do: unquote(@runtime).freeze(unquote(ctx()), unquote(value(flag)))))

  defp other(%Instruction{op: :cutscene, args: [args]} = instruction),
    do:
      continuing(
        quote(do: unquote(@runtime).cutscene(unquote(ctx()), unquote(Enum.map(args, &value/1)))),
        instruction
      )

  defp other(%Instruction{op: :end_cutscene} = instruction),
    do: continuing(quote(do: unquote(@runtime).end_cutscene(unquote(ctx()))), instruction)

  defp other(%Instruction{op: :begin_override, args: [{:begin, abort_at}]}),
    do:
      call(
        abort_at + 3,
        quote(do: unquote(@runtime).begin_override(unquote(ctx()), unquote(abort_at)))
      )

  defp other(%Instruction{op: :begin_override, args: [:end]} = instruction),
    do: next(instruction, quote(do: unquote(@runtime).end_override(unquote(ctx()))))

  defp other(%Instruction{op: op} = instruction) when op in [:debug, :dummy],
    do: next(instruction, ctx())

  defp other(%Instruction{op: :expression, args: [steps], result: result} = instruction) do
    continuing(
      quote(
        do:
          unquote(@runtime).expression(
            unquote(ctx()),
            unquote(Macro.escape(result)),
            unquote(Macro.escape(steps))
          )
      ),
      instruction
    )
  end

  defp other(
         %Instruction{op: op, args: args, result: result, offset: offset, next: next} =
           instruction
       ) do
    continuing(
      quote(
        do:
          unquote(@runtime).host(
            unquote(ctx()),
            unquote(offset),
            unquote(next),
            unquote(op),
            unquote(Macro.escape(args)),
            unquote(Macro.escape(result))
          )
      ),
      instruction
    )
  end
end
