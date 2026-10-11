# GrogVM

A SCUMM v5 script engine for Elixir. It runs the bytecode of the LucasArts adventure
games of 1990–1992 (*The Secret of Monkey Island*, *Monkey Island 2*, *Indiana Jones and
the Fate of Atlantis*) by compiling each script to an Elixir module and running it against
a *host*: a module your game writes that supplies the world the scripts talk to.

GrogVM is the engine under [MonkeyXland](https://github.com/jaman/monkey_xland), which plays *The Secret of
Monkey Island* in a terminal. GrogVM itself knows nothing about Monkey Island, rooms,
actors or pixels. It knows scripts: how to decode them, how to run them, and which of
their instructions to hand to you.

No game data is included.

## What is yours and what is GrogVM's

A SCUMM script is a stream of instructions. Some of them are the script's own business:
variables, arithmetic, jumps, comparisons, waiting out a delay, starting and stopping other
scripts, freezing them, opening and closing cutscenes. GrogVM runs all of those itself.

Everything else is a request to the game world: put an actor somewhere, print a line, load
a room, play a sound, ask what state an object is in. GrogVM decodes the instruction, reads
its variables, and hands you a plain tuple:

```elixir
{:put_actor, 1, 120, 130}
{:actor_ops, 1, [{:costume, [3]}, {:walk_speed, [8, 2]}]}
{:print, 1, [{:color, [10]}, {:text, ["Hello, I'm Guybrush Threepwood."]}]}
{:if_state, 42, 1}
```

You decide what each one means. Variables have already been replaced by their values,
messages have been decoded, and sub-operations such as `actor_ops`' list are tuples of a
name and its arguments.

## Installation

```elixir
def deps do
  [{:grog_vm, "~> 0.1"}]
end
```

Elixir 1.18 or later.

## Running a game

Three steps: compile the scripts, write a host, drive the frame loop.

### 1. Compile scripts

Scripts come out of the game's resource files as binaries. `GrogVM.Compiler.load/2` turns
one into a module, given the offsets code may start at (`[0]` for a global or local
script; an object's verb table for an object script):

```elixir
{:ok, module} = GrogVM.Compiler.load(script_bytes, [0])
```

`GrogVM.Compiler.load_all/1` compiles a list of `{bytes, entries}` pairs in parallel and
returns the modules in the same order. A game with hundreds of scripts loads them all up
front this way.

Modules are named by a digest of the bytecode, the entries and the compiler, so the same
script always compiles to the same module. Compiled modules are written to a cache
directory and loaded from there on later runs: the application setting
`:grog_vm, :cache_dir`, by default `grog_vm` under the user cache directory.

### 2. Write a host

A host implements `GrogVM.Host`, two callbacks:

```elixir
defmodule MyGame.Host do
  @behaviour GrogVM.Host

  @impl true
  def code(ctx, {:script, number}), do: ...
  def code(ctx, {:object, object, verb}), do: ...

  @impl true
  def op(ctx, {:put_actor, actor, x, y}), do: ...
  def op(ctx, {:print, actor, parts}), do: ...
  def op(ctx, {:if_state, object, state}), do: ...
end
```

`code/2` answers "where is this script?". Given `{:script, number}` or
`{:object, object, verb}`, it returns `{:ok, %{code: module, offset: offset, kind: kind}}`
with the compiled module, the offset to start at, and the script's kind (`:global`,
`:local`, `:room`, `:object` or `:inventory`), or `:none` when there is no such code.
Object verbs fall back to the default verb `0xFF`.

`op/2` runs one world operation and returns one of:

| return | meaning |
|---|---|
| `{:ok, ctx}` | done, the script continues |
| `{:ok, value, ctx}` | done, with a result: an integer for instructions that store one, a boolean for tests like `if_state` |
| `{:pause, ctx}` | done, the script waits for the next frame |
| `{:retry, ctx}` | not done yet; the script runs this instruction again next frame |

`{:retry, ctx}` is how `wait` instructions work: the host says "the actor is still
walking", the script asks again next frame.

The `ctx` is a `GrogVM.Ctx`. Its `host` field holds whatever state your game wants to
carry: the world, the screen, the sound state. Operations read and write it and return it.
A host may also call back into `GrogVM` during an operation, starting and stopping
scripts, including the one that is running.

### 3. Drive the frame loop

The game owns the main loop. SCUMM time is measured in *jiffies* (1/60 s). Each frame the
game counts the elapsed jiffies off waiting scripts and runs every script that is due:

```elixir
ctx = GrogVM.new(MyGame.Host, MyGame.World.new())
ctx = GrogVM.start_script(ctx, 1, [])

loop = fn ctx, loop ->
  jiffies = elapsed_since_last_frame()
  ctx = GrogVM.run_frame(ctx, jiffies)
  ctx = handle_player_input(ctx)
  loop.(ctx, loop)
end
```

Script 1 is conventionally the boot script. Between frames the game starts whatever
scripts the player's actions call for: `GrogVM.start_script/4` for a numbered script,
`GrogVM.start_object/5` for an object's verb, `GrogVM.start_code/5` for code the game
found itself, such as a room's entry script. `GrogVM.abort_cutscene/1` skips the current
cutscene when the player presses Escape.

A started script runs at once, inside whatever started it, until it first pauses or ends.
Then its starter goes on.

The context is a plain value. A game saves by serialising it, may hold more than one, and
can run frames in tests with nothing started.

## Looking inside

* `GrogVM.var/2` and `GrogVM.put_var/3` read and write global variables. Games keep their
  configuration in them (machine speed, sound card, the key that skips a cutscene), set
  before the boot script runs.
* `GrogVM.scripts/1` lists every script running or waiting, as `GrogVM.Slot` structs:
  number, kind, where it is in its code, whether it is paused or frozen, its 25 locals.
* `GrogVM.running?/2`, `GrogVM.current/1` and `GrogVM.sentences_frozen?/1` answer the
  questions a game's input handling asks.
* `GrogVM.Decode.program/2` decodes a script into `GrogVM.Instruction` structs by offset
  without compiling it, for reading or disassembling one.

## What the machine does itself

So you know what *not* to implement in a host:

* **Variables.** Global word variables, bit variables, each script's locals, and indexed
  references (`GrogVM.Var`).
* **Arithmetic and tests.** `move`, `add`, `subtract`, `multiply`, `divide`, `and`, `or`,
  `increment`, `decrement`, `set_var_range`, the comparisons, `expression` stacks and
  `get_random_nr`.
* **Control.** `jump_relative`, `break_here`, `delay`, `delay_variable`, `stop_object_code`.
* **Scripts.** Up to 40 slots. `start_script`, `chain_script`, `start_object`,
  `stop_script`, `stop_object_script`, `is_script_running`, recursive and
  freeze-resistant starts, `freeze_scripts`.
* **Cutscenes.** `cutscene`, `end_cutscene`, `begin_override`, the cutscene stack, the
  cutscene start and end scripts (variables 35 and 36 by default), and skipping.

Every other instruction name in `GrogVM.Decode.Table` arrives at your host's `op/2`.

A script that loops without ever pausing is stopped with an error after a large number of
jumps, so a bad script cannot hang the game.

## Configuration

`GrogVM.new/3` takes options passed on to `GrogVM.Machine.new/1`:

* `config:` a map of the variable numbers the machine itself uses: `override`,
  `cutscene_start_script`, `cutscene_end_script`. Defaults are SCUMM v5's 5, 35 and 36.
* `seed:` the random number seed.

## Reading more

* [MonkeyXland](https://github.com/jaman/monkey_xland) is a complete host: one module per subject (actors,
  objects, rooms, interface, audio), each handling the operations named for it.
* The [ScummVM](https://www.scummvm.org/) source and the
  [SCUMM technical reference](https://wiki.scummvm.org/index.php/SCUMM/Technical_Reference)
  document the opcodes and the engine behaviour GrogVM reproduces.

## License

MIT.
