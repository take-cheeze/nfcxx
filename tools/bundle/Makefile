# Builds build/nfcbundle (docs/notes/bundle.md).
CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
root := $(abspath ../..)

$(root)/build/nfcbundle: nfcbundle.cpp
	@mkdir -p $(root)/build
	$(CXX) $(CXXFLAGS) -o $@.tmp.$$$$ $< && mv -f $@.tmp.$$$$ $@
