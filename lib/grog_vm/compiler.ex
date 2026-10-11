defmodule GrogVM.Compiler do
  @moduledoc """
  Compiles SCUMM v5 bytecode into Elixir modules.

      {:ok, module} = GrogVM.Compiler.load(code, [0])
      step = module.run(0, ctx)

  A module has `run(offset, ctx)` for every instruction reachable from the entries, and
  returns the steps described in `GrogVM.Runtime`. Modules are named by a digest of the
  code, its entries and the compiler itself; a module already loaded is reused, and the
  compiled code is kept in the cache directory (the application setting
  `:grog_vm, :cache_dir`, by default the user cache directory's `grog_vm`) so each piece
  of code is compiled once per machine.
  """

  alias GrogVM.Compiler.Emit
  alias GrogVM.Decode

  @doc "The module for `code` started at `entries`, compiling it when needed."
  @spec load(binary(), [non_neg_integer()]) :: {:ok, module()} | {:error, Decode.error()}
  def load(code, entries) do
    name = name(code, entries)

    if Code.ensure_loaded?(name),
      do: {:ok, name},
      else:
        :global.trans({{__MODULE__, name}, self()}, fn -> load_locked(name, code, entries) end)
  end

  @doc "Loads many programs at once, compiling in parallel; returns them in the given order."
  @spec load_all([{binary(), [non_neg_integer()]}]) :: [
          {:ok, module()} | {:error, Decode.error()}
        ]
  def load_all(programs) do
    loaded =
      programs
      |> Enum.uniq()
      |> Task.async_stream(fn program -> {program, load(elem(program, 0), elem(program, 1))} end,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, loaded} -> loaded end)

    Enum.map(programs, &Map.fetch!(loaded, &1))
  end

  defp load_locked(name, code, entries) do
    if Code.ensure_loaded?(name),
      do: {:ok, name},
      else: load_cached(name) || compile(name, code, entries)
  end

  defp name(code, entries) do
    digest = :crypto.hash(:sha256, [code, :erlang.term_to_binary(entries), compiler_digest()])

    Module.concat(
      GrogVM.Compiled,
      "C" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 24))
    )
  end

  defp compiler_digest do
    for module <- [
          __MODULE__,
          Emit,
          Decode,
          Decode.Operands,
          Decode.SubOps,
          Decode.Layout,
          Decode.Cursor,
          Decode.Table,
          GrogVM.Text,
          GrogVM.Var
        ],
        into: <<>>,
        do: module.module_info(:md5)
  end

  defp cache_path(name) do
    dir = Application.get_env(:grog_vm, :cache_dir) || :filename.basedir(:user_cache, "grog_vm")
    Path.join(to_string(dir), "#{name}.beam")
  end

  defp load_cached(name) do
    with {:ok, binary} <- File.read(cache_path(name)),
         {:module, ^name} <- :code.load_binary(name, ~c"#{name}", binary) do
      {:ok, name}
    else
      _missing -> nil
    end
  end

  defp compile(name, code, entries) do
    with {:ok, program} <- Decode.program(code, entries) do
      [{^name, binary}] = name |> Emit.module(program) |> Code.compile_quoted("grog_vm")
      save(name, binary)
      {:ok, name}
    end
  end

  defp save(name, binary) do
    path = cache_path(name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, binary)
  end
end
