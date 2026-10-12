//go:build !linux

package main

// currentThread is unknown here; the host still refuses calls that arrive on another thread (nfcpoly_go.cpp).
func currentThread() int64 { return 0 }
