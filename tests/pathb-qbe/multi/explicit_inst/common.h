#pragma once
// Explicit instantiation definitions in a.cpp only; b.cpp uses the instances through these declarations.
template <int N> void rep(int * p, int n);
template <int N> int get(int x);
int b_work();
