#pragma once
// PROGRAM_OWNER_SITES (symbol_cache.rb): the one VM and epoch every compiled gem's program-wide owner sites
// (BC2CPP_OWNERS_PW) are dated by. Included at file scope by each gem, so `inline` makes one of each per program.
struct mrb_state;
inline mrb_state* bc2cpp_program_owner_vm = nullptr;
inline unsigned bc2cpp_program_owner_epoch = 1;
