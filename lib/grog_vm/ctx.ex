defmodule GrogVM.Ctx do
  @moduledoc """
  What compiled scripts and host operations pass along: the machine, the host's own
  state and module, and the script running now.

    * `slot`, `slot_id` — the index and id of the running script, `nil` between scripts,
    * `at` — the offset of the instruction a host operation was called from,
    * `depth` — how many scripts deep nested starts have gone,
    * `ran` — the ids of the scripts that have run this frame,
    * `budget` — jumps left before a script that never pauses is stopped with an error.
  """

  alias GrogVM.Machine

  @budget 100_000

  @enforce_keys [:machine, :host, :host_module]
  defstruct [
    :machine,
    :host,
    :host_module,
    slot: nil,
    slot_id: nil,
    at: nil,
    depth: 0,
    ran: MapSet.new(),
    budget: @budget
  ]

  @type t :: %__MODULE__{
          machine: Machine.t(),
          host: term(),
          host_module: module(),
          slot: non_neg_integer() | nil,
          slot_id: pos_integer() | nil,
          at: non_neg_integer() | nil,
          depth: non_neg_integer(),
          ran: MapSet.t(pos_integer()),
          budget: non_neg_integer()
        }

  @doc "A context for `host_module` with `host` state and `machine`."
  @spec new(module(), term(), Machine.t()) :: t()
  def new(host_module, host, machine),
    do: %__MODULE__{machine: machine, host: host, host_module: host_module}

  @doc "The jump budget a script starts each run with."
  @spec budget() :: pos_integer()
  def budget, do: @budget
end
