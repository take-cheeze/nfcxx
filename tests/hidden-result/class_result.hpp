#pragma once
// A class result EDG lowers into a hidden first parameter (a non-trivially-copyable class: std::string, std::optional of one):
// the caller and the defining unit are different translation units, so the AAPCS64 x8 convention must match on both sides
// (scripts/pathb-ssa-qbe.rb, hidden-result). The virtual and pointer calls go through the thunks of the indirect form.
#include <optional>
#include <string>
#include <string_view>
struct Base { virtual ~Base() {} virtual std::string who(int k) const = 0; };
struct Impl : Base { std::string who(int k) const override; };
std::string make(int a, std::string_view k);                 // defined in lib.cpp
std::optional<std::string> maybe(int k);                    // defined in lib.cpp
std::string through(std::string (*f)(int), int k);          // defined in lib.cpp
struct Holder { int tag = 7; std::string name(std::string_view k) const; };   // defined in lib.cpp
