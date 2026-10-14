# Builds build/cuda-rewrite (the C++ port of scripts/cuda-rewrite.rb). See PORTING.md.
CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
root := $(abspath ../..)

$(root)/build/cuda-rewrite: cuda_rewrite.cpp
	@mkdir -p $(root)/build
	$(CXX) $(CXXFLAGS) -o $@ $<
