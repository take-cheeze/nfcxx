# Builds build/pathb-ptx-emit (the C++ port of scripts/pathb-ptx-emit.rb; phase 1 is the reader). See ../cuda-rewrite.
CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
root := $(abspath ../..)
srcs := ir.cpp main.cpp lower_types.cpp eval_cases.cpp lower_arith.cpp lower_call.cpp eval_arith.cpp

$(root)/build/pathb-ptx-emit: $(srcs) ir.hpp
	@mkdir -p $(root)/build
	$(CXX) $(CXXFLAGS) -o $@ $(srcs)
