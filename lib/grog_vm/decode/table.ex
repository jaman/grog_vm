defmodule GrogVM.Decode.Table do
  @moduledoc """
  The name of every SCUMM v5 opcode.

  The bits `0x80`, `0x40` and `0x20` of most opcodes only choose whether parameters are
  variables, so most names repeat across the four quarters of the table; the opcodes
  listed in `@upper` name a different instruction in the upper half.
  """

  @lower ~w(
    stop_object_code put_actor start_music get_actor_room
    is_greater_equal draw_object get_actor_elevation set_state
    is_not_equal face_actor start_script get_verb_entrypoint
    resource_routines walk_actor_to_actor put_actor_at_object get_object_state
    get_object_owner animate_actor pan_camera_to actor_ops
    print actor_from_pos get_random_nr and
    jump_relative do_sentence move multiply
    start_sound if_class_of_is walk_actor_to is_actor_in_box
    stop_music put_actor get_anim_counter get_actor_y
    load_room_with_ego pickup_object set_var_range string_ops
    equal_zero set_owner_of start_script delay_variable
    cursor_command put_actor_in_room delay if_not_state
    matrix_ops get_inventory_count set_camera_at room_ops
    get_dist find_object walk_actor_to_object start_object
    is_less_equal do_sentence subtract get_actor_scale
    stop_sound find_inventory walk_actor_to draw_box
    cutscene put_actor chain_script get_actor_x
    is_less draw_object increment set_state
    is_equal face_actor start_script get_verb_entrypoint
    sound_kludge walk_actor_to_actor put_actor_at_object if_state
    pickup_object_old animate_actor actor_follow_camera actor_ops
    set_object_name actor_from_pos get_actor_moving or
    begin_override do_sentence add divide
    old_room_effect set_class walk_actor_to is_actor_in_box
    freeze_scripts put_actor stop_script get_actor_facing
    load_room_with_ego pickup_object get_closest_obj_actor get_string_width
    is_script_running set_owner_of start_script debug
    get_actor_width put_actor_in_room stop_object_script if_not_state
    lights get_actor_costume load_room room_ops
    get_dist find_object walk_actor_to_object start_object
    is_greater do_sentence verb_ops get_actor_walk_box
    is_sound_running find_inventory walk_actor_to draw_box
  )a

  @upper %{
    0x80 => :break_here,
    0x98 => :system_ops,
    0xA0 => :stop_object_code,
    0xA7 => :dummy,
    0xA8 => :not_equal_zero,
    0xAB => :save_restore_verbs,
    0xAC => :expression,
    0xAE => :wait,
    0xC0 => :end_cutscene,
    0xC6 => :decrement,
    0xCC => :pseudo_room,
    0xD8 => :print_ego
  }

  @names @lower |> Enum.with_index() |> Map.new(fn {name, opcode} -> {opcode, name} end)

  @doc "The instruction an opcode byte names."
  @spec name(byte()) :: atom()
  def name(opcode) when opcode >= 0x80,
    do: Map.get(@upper, opcode, Map.fetch!(@names, opcode - 0x80))

  def name(opcode), do: Map.fetch!(@names, opcode)
end
