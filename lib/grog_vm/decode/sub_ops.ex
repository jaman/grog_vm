defmodule GrogVM.Decode.SubOps do
  @moduledoc """
  Instructions whose parameters depend on a sub-operation byte, or that otherwise do
  not follow one fixed layout.

  A sub-operation is returned as `{name, args}`. Instructions that repeat
  sub-operations (`actor_ops`, `verb_ops`, `print`, `print_ego`) take a list of them,
  ending at a `0xFF` byte, or for `print` after a `{:text, message}`.
  """

  import Bitwise

  alias GrogVM.Decode
  alias GrogVM.Decode.{Cursor, Layout}

  @actor_ops %{
    0 => {:dummy, [:b1]},
    1 => {:costume, [:b1]},
    2 => {:walk_speed, [:b1, :b2]},
    3 => {:sound, [:b1]},
    4 => {:walk_animation, [:b1]},
    5 => {:talk_animation, [:b1, :b2]},
    6 => {:stand_animation, [:b1]},
    7 => {:animations, [:b1, :b2, :b3]},
    8 => {:init, []},
    9 => {:elevation, [:w1]},
    10 => {:default_animations, []},
    11 => {:palette, [:b1, :b2]},
    12 => {:talk_color, [:b1]},
    13 => {:name, [:text]},
    14 => {:init_animation, [:b1]},
    16 => {:width, [:b1]},
    17 => {:scale, [:b1, :b2]},
    18 => {:never_z_clip, []},
    19 => {:always_z_clip, [:b1]},
    20 => {:ignore_boxes, []},
    21 => {:follow_boxes, []},
    22 => {:animation_speed, [:b1]},
    23 => {:shadow, [:b1]}
  }

  @verb_ops %{
    1 => {:image, [:w1]},
    2 => {:name, [:text]},
    3 => {:color, [:b1]},
    4 => {:hi_color, [:b1]},
    5 => {:at, [:w1, :w2]},
    6 => {:on, []},
    7 => {:off, []},
    8 => {:delete, []},
    9 => {:new, []},
    16 => {:dim_color, [:b1]},
    17 => {:dim, []},
    18 => {:key, [:b1]},
    19 => {:center, []},
    20 => {:name_from_string, [:w1]},
    22 => {:image_from_object, [:w1, :b2]},
    23 => {:back_color, [:b1]}
  }

  @print_ops %{
    0 => {:at, [:w1, :w2]},
    1 => {:color, [:b1]},
    2 => {:clipped, [:w1]},
    3 => {:erase, [:w1, :w2]},
    4 => {:center, []},
    6 => {:left, []},
    7 => {:overhead, []},
    8 => {:voice, [:w1, :w2]},
    15 => {:text, [:text]}
  }

  @cursor_ops %{
    1 => {:cursor_on, []},
    2 => {:cursor_off, []},
    3 => {:userput_on, []},
    4 => {:userput_off, []},
    5 => {:cursor_soft_on, []},
    6 => {:cursor_soft_off, []},
    7 => {:userput_soft_on, []},
    8 => {:userput_soft_off, []},
    10 => {:image, [:b1, :b2]},
    11 => {:hotspot, [:b1, :b2, :b3]},
    12 => {:cursor, [:b1]},
    13 => {:charset, [:b1]},
    14 => {:charset_colors, [:list]}
  }

  @string_ops %{
    1 => {:load, [:b1, :text]},
    2 => {:copy, [:b1, :b2]},
    3 => {:set_char, [:b1, :b2, :b3]},
    4 => {:get_char, [:result, :b1, :b2]},
    5 => {:create, [:b1, :b2]}
  }

  @room_ops %{
    1 => {:scroll, [:w1, :w2]},
    3 => {:screen, [:w1, :w2]},
    4 => {:palette, [:w1, :w2, :w3, :sub_op, :b1]},
    5 => {:shake_on, []},
    6 => {:shake_off, []},
    7 => {:scale, [:b1, :b2, :sub_op, :b1, :b2, :sub_op, :b2]},
    8 => {:intensity, [:b1, :b2, :b3]},
    9 => {:save_load, [:b1, :b2]},
    10 => {:effect, [:w1]},
    11 => {:rgb_intensity, [:w1, :w2, :w3, :sub_op, :b1, :b2]},
    12 => {:shadow, [:w1, :w2, :w3, :sub_op, :b1, :b2]},
    13 => {:save_string, [:b1, :text]},
    14 => {:load_string, [:b1, :text]},
    15 => {:palette_manipulate, [:b1, :sub_op, :b1, :b2, :sub_op, :b1]},
    16 => {:cycle_delay, [:b1, :b2]}
  }

  @matrix_ops %{
    1 => {:box_flags, [:b1, :b2]},
    2 => {:box_scale, [:b1, :b2]},
    3 => {:box_scale, [:b1, :b2]},
    4 => {:create_box_matrix, []}
  }

  @resources ~w(load_script load_sound load_costume load_room nuke_script nuke_sound
    nuke_costume nuke_room lock_script lock_sound lock_costume lock_room unlock_script
    unlock_sound unlock_costume unlock_room clear_heap load_charset nuke_charset
    load_object)a
             |> Enum.with_index(1)
             |> Map.new(fn {name, code} -> {code, name} end)

  @wait_ops %{1 => {:actor, [:b1]}, 2 => {:message, []}, 3 => {:camera, []}, 4 => {:sentence, []}}

  @draw_object_ops %{1 => {:at, [:w1, :w2]}, 2 => {:state, [:w1]}, 0x1F => {:draw, []}}

  @save_restore_ops %{1 => :save, 2 => :restore, 3 => :delete}

  @doc "Reads the parameters of instruction `name` at `cursor`."
  @spec read(atom(), Cursor.t()) :: {Layout.read(), Cursor.t()}
  def read(:actor_ops, cursor), do: subject_and_repeated(cursor, :b1, @actor_ops, 0x1F)
  def read(:verb_ops, cursor), do: subject_and_repeated(cursor, :b1, @verb_ops, 0x1F)
  def read(:print, cursor), do: subject_and_repeated(cursor, :b1, @print_ops, 0x0F)
  def read(:print_ego, cursor), do: args_only(repeated(cursor, @print_ops, 0x0F, []), &[&1])
  def read(:cursor_command, cursor), do: single(cursor, @cursor_ops)
  def read(:string_ops, cursor), do: single(cursor, @string_ops)
  def read(:room_ops, cursor), do: single(cursor, @room_ops)
  def read(:matrix_ops, cursor), do: single(cursor, @matrix_ops)
  def read(:wait, cursor), do: single(cursor, @wait_ops)
  def read(:resource_routines, cursor), do: resource(Cursor.sub_op(cursor))
  def read(:draw_object, cursor), do: draw_object(cursor)
  def read(:do_sentence, cursor), do: do_sentence(Cursor.byte_param(cursor, 0x80))
  def read(:if_class_of_is, cursor), do: if_class_of_is(cursor)
  def read(:set_var_range, cursor), do: set_var_range(cursor)
  def read(:delay, cursor), do: delay(cursor)
  def read(:begin_override, cursor), do: begin_override(Cursor.byte(cursor))
  def read(:old_room_effect, cursor), do: old_room_effect(Cursor.sub_op(cursor))
  def read(:save_restore_verbs, cursor), do: save_restore_verbs(Cursor.sub_op(cursor))
  def read(:pseudo_room, cursor), do: pseudo_room(Cursor.byte(cursor))
  def read(:start_script, cursor), do: start_script(cursor)
  def read(:expression, cursor), do: expression(cursor)

  defp plain(args), do: %{args: args, result: nil, target: nil}

  defp args_only({args, cursor}, wrap), do: {plain(wrap.(args)), cursor}

  defp subject_and_repeated(cursor, subject, table, mask) do
    {[who], cursor} = Layout.args([subject], cursor)
    {ops, cursor} = repeated(cursor, table, mask, [])
    {plain([who, ops]), cursor}
  end

  defp repeated(cursor, table, mask, acc) do
    case Cursor.sub_op(cursor) do
      {0xFF, cursor} -> {Enum.reverse(acc), cursor}
      {selector, cursor} -> repeated_op(table, selector &&& mask, cursor, mask, acc)
    end
  end

  defp repeated_op(table, code, cursor, mask, acc) do
    {name, layout} = Map.fetch!(table, code)
    {args, cursor} = Layout.args(layout, cursor)
    next_repeated({name, args}, cursor, table, mask, acc)
  end

  defp next_repeated({:text, _args} = op, cursor, _table, _mask, acc),
    do: {Enum.reverse([op | acc]), cursor}

  defp next_repeated(op, cursor, table, mask, acc), do: repeated(cursor, table, mask, [op | acc])

  defp single(cursor, table) do
    {selector, cursor} = Cursor.sub_op(cursor)
    {name, layout} = Map.fetch!(table, selector &&& 0x1F)
    {read, cursor} = Layout.read(layout, cursor)
    {%{read | args: [{name, read.args}]}, cursor}
  end

  defp resource({selector, cursor}) do
    name = Map.fetch!(@resources, selector &&& 0x3F)
    layout = resource_layout(name)
    {args, cursor} = Layout.args(layout, cursor)
    {plain([{name, args}]), cursor}
  end

  defp resource_layout(:clear_heap), do: []
  defp resource_layout(:load_object), do: [:b1, :w2]
  defp resource_layout(_name), do: [:b1]

  defp draw_object(cursor) do
    {[object], cursor} = Layout.args([:w1], cursor)
    {selector, cursor} = Cursor.sub_op(cursor)
    {name, layout} = Map.fetch!(@draw_object_ops, selector &&& 0x1F)
    {args, cursor} = Layout.args(layout, cursor)
    {plain([object, {name, args}]), cursor}
  end

  defp do_sentence({{:imm, 0xFE}, cursor}), do: {plain([:stop]), cursor}

  defp do_sentence({verb, cursor}) do
    {args, cursor} = Layout.args([:w2, :w3], cursor)
    {plain([verb | args]), cursor}
  end

  defp if_class_of_is(cursor) do
    {[object], cursor} = Layout.args([:w1], cursor)
    {classes, cursor} = Cursor.word_list(cursor)
    {target, cursor} = Cursor.jump(cursor)
    {%{args: [object, classes], result: nil, target: target}, cursor}
  end

  defp set_var_range(%Cursor{op: opcode} = cursor) do
    {result, cursor} = Cursor.var(cursor)
    {count, cursor} = Cursor.byte(cursor)
    reader = if (opcode &&& 0x80) != 0, do: &Cursor.signed_word/1, else: &Cursor.byte/1

    {values, cursor} =
      Enum.map_reduce(List.duplicate(reader, count), cursor, fn read, at -> read.(at) end)

    {%{args: [Enum.map(values, &{:imm, &1})], result: result, target: nil}, cursor}
  end

  defp delay(cursor) do
    {low, cursor} = Cursor.byte(cursor)
    {middle, cursor} = Cursor.byte(cursor)
    {high, cursor} = Cursor.byte(cursor)
    {plain([{:imm, low ||| middle <<< 8 ||| high <<< 16}]), cursor}
  end

  defp begin_override({0, cursor}), do: {plain([:end]), cursor}

  defp begin_override({_flag, %Cursor{pos: abort_at} = cursor}) do
    {0x18, _after_opcode} = Cursor.byte(cursor)
    {plain([{:begin, abort_at}]), cursor}
  end

  defp old_room_effect({selector, cursor}) when (selector &&& 0x1F) == 3,
    do: args_only(Layout.args([:w1], cursor), &[{:effect, &1}])

  defp old_room_effect({selector, cursor}),
    do: {plain([{:other, [{:imm, selector &&& 0x1F}]}]), cursor}

  defp save_restore_verbs({selector, cursor}) do
    {args, cursor} = Layout.args([:b1, :b2, :b3], cursor)
    {plain([{Map.fetch!(@save_restore_ops, selector &&& 0x1F), args}]), cursor}
  end

  defp pseudo_room({room, cursor}), do: pseudo_rooms(cursor, room, [])

  defp pseudo_rooms(cursor, room, acc) do
    case Cursor.byte(cursor) do
      {0, cursor} -> {plain([{:imm, room}, Enum.reverse(acc)]), cursor}
      {byte, cursor} -> pseudo_rooms(cursor, room, [{:imm, byte} | acc])
    end
  end

  defp start_script(%Cursor{op: opcode} = cursor) do
    {[script, args], cursor} = Layout.args([:b1, :list], cursor)
    flags = %{recursive: (opcode &&& 0x40) != 0, freeze_resistant: (opcode &&& 0x20) != 0}
    {plain([script, args, flags]), cursor}
  end

  defp expression(cursor) do
    {result, cursor} = Cursor.var(cursor)
    {steps, cursor} = expression_steps(cursor, [])
    {%{args: [steps], result: result, target: nil}, cursor}
  end

  defp expression_steps(cursor, acc) do
    case Cursor.sub_op(cursor) do
      {0xFF, cursor} -> {Enum.reverse(acc), cursor}
      {selector, cursor} -> expression_step(selector &&& 0x1F, cursor, acc)
    end
  end

  defp expression_step(1, cursor, acc) do
    {[value], cursor} = Layout.args([:w1], cursor)
    expression_steps(cursor, [{:push, value} | acc])
  end

  defp expression_step(6, %Cursor{code: code, pos: pos} = cursor, acc) do
    {:ok, nested} = Decode.instruction(code, pos)
    expression_steps(%{cursor | pos: nested.next}, [{:op, nested} | acc])
  end

  defp expression_step(code, cursor, acc) when code in 2..5,
    do: expression_steps(cursor, [Enum.at([:add, :subtract, :multiply, :divide], code - 2) | acc])
end
