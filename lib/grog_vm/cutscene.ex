defmodule GrogVM.Cutscene do
  @moduledoc """
  Cutscenes and skipping them.

  `open/2` pushes a level onto the cutscene stack, counts it against the running script,
  and runs the script named by the cutscene start variable with the same arguments;
  `close/1` pops it and runs the end script with the argument the level was opened with.
  Between them, `begin_override/2` records where the running script resumes when the
  player skips, and `abort/1` sends it there and sets the override variable to 1.
  """

  alias GrogVM.{Ctx, Machine, Scripts}

  @doc "Opens a cutscene with `args`."
  @spec open(Ctx.t(), [integer()]) :: Ctx.t()
  def open(%Ctx{machine: machine, slot: index} = ctx, args) do
    level = %{data: List.first(args, 0), slot: nil, abort_at: nil}

    machine =
      machine
      |> Machine.update_slot(index, &%{&1 | cutscene_override: &1.cutscene_override + 1})
      |> Map.update!(:cutscenes, &[level | &1])
      |> Map.put(:cutscene_slot, index)

    ctx = %{ctx | machine: machine} |> run_var_script(:cutscene_start_script, args)
    %{ctx | machine: %{ctx.machine | cutscene_slot: nil}}
  end

  @doc "Closes the innermost cutscene."
  @spec close(Ctx.t()) :: Ctx.t()
  def close(%Ctx{machine: %Machine{cutscenes: [level | rest]} = machine, slot: index} = ctx) do
    machine =
      machine
      |> Machine.update_slot(
        index,
        &%{&1 | cutscene_override: closed_override(&1.cutscene_override, level)}
      )
      |> Machine.put_var(machine.config.override, 0)
      |> Map.put(:cutscenes, base_kept(rest))

    run_var_script(%{ctx | machine: machine}, :cutscene_end_script, [level.data])
  end

  @doc "Records that skipping resumes the running script at `abort_at`."
  @spec begin_override(Ctx.t(), non_neg_integer()) :: Ctx.t()
  def begin_override(%Ctx{machine: machine, slot: index} = ctx, abort_at) do
    machine =
      machine
      |> top(&%{&1 | slot: index, abort_at: abort_at})
      |> Machine.put_var(machine.config.override, 0)

    %{ctx | machine: machine}
  end

  @doc "Clears the innermost cutscene's resume point."
  @spec end_override(Ctx.t()) :: Ctx.t()
  def end_override(%Ctx{machine: machine} = ctx) do
    machine =
      machine
      |> top(&%{&1 | slot: nil, abort_at: nil})
      |> Machine.put_var(machine.config.override, 0)

    %{ctx | machine: machine}
  end

  @doc """
  Skips the innermost cutscene when it has a resume point: its script continues there,
  running and with no delay, and the override variable becomes 1.
  """
  @spec abort(Machine.t()) :: Machine.t()
  def abort(%Machine{cutscenes: [%{abort_at: nil} | _rest]} = machine), do: machine

  def abort(%Machine{cutscenes: [%{slot: index, abort_at: abort_at} | _rest]} = machine) do
    machine
    |> Machine.update_slot(index, &resume_at(&1, abort_at))
    |> Machine.put_var(machine.config.override, 1)
    |> top(&%{&1 | abort_at: nil})
  end

  defp resume_at(slot, abort_at),
    do: %{
      slot
      | offset: abort_at,
        status: :running,
        delay: 0,
        cutscene_override: max(slot.cutscene_override - 1, 0)
    }

  defp closed_override(count, %{abort_at: nil}), do: max(count - 1, 0)
  defp closed_override(count, _level), do: max(count - 2, 0)

  defp base_kept([]), do: [%{data: 0, slot: nil, abort_at: nil}]
  defp base_kept(levels), do: levels

  defp top(%Machine{cutscenes: [level | rest]} = machine, change),
    do: %{machine | cutscenes: [change.(level) | rest]}

  defp run_var_script(%Ctx{machine: machine} = ctx, key, args),
    do: Scripts.start(ctx, Machine.var(machine, Map.fetch!(machine.config, key)), args, [])
end
