defmodule GrogVM.Host do
  @moduledoc """
  What a game supplies to run SCUMM v5 scripts: everything that is not variables,
  arithmetic, jumps or script control.

  `c:op/2` receives one operation as a tuple whose first element is the instruction's
  name and whose other elements are its parameters, already read: variables are
  replaced by their values, messages (`GrogVM.Text`) have their `{:int, _}`,
  `{:verb, _}`, `{:name, _}` and `{:string, _}` parts read, and sub-operations are
  `{name, [values]}`. For example:

      {:put_actor, actor, x, y}
      {:actor_ops, actor, [{:costume, [3]}, {:walk_speed, [8, 2]}]}
      {:print, actor, [{:color, [10]}, {:text, [message]}]}
      {:if_state, object, state}

  The operations are the instruction names of `GrogVM.Decode.Table` other than those
  the machine runs itself: `stop_object_code`, `break_here`, `jump_relative`, the
  comparisons (`is_equal` … `not_equal_zero`), `move`, `add`, `subtract`, `multiply`,
  `divide`, `and`, `or`, `increment`, `decrement`, `set_var_range`, `get_random_nr`,
  `expression`, `delay`, `delay_variable`, `start_script`, `chain_script`,
  `start_object`, `stop_script`, `stop_object_script`, `freeze_scripts`,
  `is_script_running`, `cutscene`, `end_cutscene`, `begin_override`, `debug` and
  `dummy`.

  An operation returns:

    * `{:ok, ctx}` — done; the script goes on,
    * `{:ok, value, ctx}` — for an instruction with a result, the value stored into it;
      for a test (`if_state`, `if_not_state`, `is_actor_in_box`, `if_class_of_is`) a
      boolean, `true` when the test holds and the script falls through,
    * `{:pause, ctx}` — done; the script waits for the next frame,
    * `{:retry, ctx}` — not done yet; the script waits and runs this instruction again
      next frame (the `wait` instruction's conditions, for one).

  The host may start and stop scripts through `GrogVM` during an operation, including
  the one running; a script that finds itself stopped ends at once.
  """

  alias GrogVM.{Ctx, Slot}

  @typedoc "Where a script's code is: its compiled module, the offset to start at, its kind."
  @type code :: %{code: module(), offset: non_neg_integer(), kind: Slot.kind()}

  @doc "Runs one operation."
  @callback op(Ctx.t(), tuple()) ::
              {:ok, Ctx.t()}
              | {:ok, integer() | boolean(), Ctx.t()}
              | {:pause, Ctx.t()}
              | {:retry, Ctx.t()}

  @doc """
  Finds code to start: `{:script, number}` for a global (below 200) or local script, or
  `{:object, object, verb}` for an object's verb (falling back to its default verb
  `0xFF`). `:none` when there is no such code.
  """
  @callback code(
              Ctx.t(),
              {:script, non_neg_integer()} | {:object, non_neg_integer(), non_neg_integer()}
            ) ::
              {:ok, code()} | :none
end
