#pragma once
#include <mruby.h>

mrb_value Foo_initialize_impl(mrb_state*, mrb_value);
mrb_value Foo_size2_impl(mrb_state*, mrb_value);
mrb_value Menu_pick_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
mrb_value Menu_add_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
mrb_value Menu_computed_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
mrb_value Menu_later_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_value, mrb_int);
mrb_value Menu_loose_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
mrb_value Menu_sorted_impl(mrb_state*, mrb_value, mrb_value, mrb_value, mrb_int);
mrb_value Menu_keys_of_impl(mrb_state*, mrb_value, mrb_value);
mrb_value Menu_shout_impl(mrb_state*, mrb_value, mrb_value);
mrb_value Menu_run_impl(mrb_state*, mrb_value);
mrb_value Menu_wrong_sorted_impl(mrb_state*, mrb_value);
mrb_value Menu_wrong_impl(mrb_state*, mrb_value);
mrb_value Menu_wrong_add_impl(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Foo_initialize(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Foo_size2(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_pick(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_add(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_computed(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_later(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_loose(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_sorted(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_keys_of(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_shout(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_run(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_wrong_sorted(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_wrong(mrb_state*, mrb_value);
mrb_value bc2cpp_xrow_Menu_wrong_add(mrb_state*, mrb_value);

