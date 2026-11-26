#!/usr/bin/env ruby
# synth.rb OUT.cnut: writes a hand-assembled Squirrel 3.2 bytecode stream, in the layout of sqobject.cpp's SQClosure::Save
# and SQFunctionProto::Save (sizes 1, 8, 4), for the opcodes the default compiler does not emit: LINE, DLOAD, DMOVE and
# LOADNULLS with a count. The reference VM runs the same stream (sqref), so the program has an oracle without a source.
#
# The main prototype computes 10000000000 + -7 through two DLOADs, two DMOVEs and an ADD, and returns the sum; the
# expected result is 9999999993.
out = ARGV.fetch(0)

def u32(v) = [v].pack("V")
def i64(v) = [v].pack("q<")
def str_obj(s) = u32(0x08000010) + i64(s.bytesize) + s.b
def int_obj(v) = u32(0x05000002) + i64(v)

# SQ_CLOSURESTREAM_PART is 'P','A','R','T' read as a u32 (LE bytes "TRAP"); HEAD and TAIL likewise.
PART = "TRAP"
HEAD = "RIQS"
TAIL = "LIAT"

# One SQInstruction: arg1 (SQInt32) first, then op, arg0, arg2, arg3.
def instr(op, arg0, arg1, arg2, arg3) = [arg1].pack("l<") + [op, arg0, arg2, arg3].pack("C4")

instructions = [
  instr(0x00, 0, 1, 0, 0),    # LINE 1
  instr(0x04, 2, 0, 3, 1),    # DLOAD r2 = lit0, r3 = lit1
  instr(0x1B, 4, 2, 5, 3),    # DMOVE r4 = r2, r5 = r3
  instr(0x18, 6, 3, 0, 0),    # LOADNULLS r6..r8
  instr(0x1B, 9, 4, 10, 5),   # DMOVE r9 = r4, r10 = r5
  instr(0x11, 11, 10, 9, 0),  # ADD r11 = r9 + r10
  instr(0x17, 1, 11, 0, 0),   # RETURN r11
]

buf = "".b
buf << [0xFAFA].pack("v")
buf << HEAD
buf << u32(1) << u32(8) << u32(4)
buf << PART
buf << str_obj("synth.nut") << str_obj("main")
buf << PART
buf << [2, 1, 0, 0, 0, 0, instructions.size, 0].map { |n| i64(n) }.join
buf << PART
buf << int_obj(10_000_000_000) << int_obj(-7)
buf << PART
buf << str_obj("this")
buf << PART                # outers
buf << PART                # local variable infos
buf << PART                # line infos
buf << PART                # default parameters
buf << PART
buf << instructions.join
buf << PART                # functions
buf << i64(16)             # stacksize
buf << "\x00".b            # bgenerator
buf << i64(0)              # varparams
buf << TAIL

File.binwrite(out, buf)
