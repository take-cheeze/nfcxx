//go:build linux

package main

import "syscall"

// currentThread is the operating system thread the calling goroutine runs on. A goroutine that cgo entered from C is
// locked to the thread of the C caller for the duration of the call, so this identifies the host thread.
func currentThread() int64 { return int64(syscall.Gettid()) }
