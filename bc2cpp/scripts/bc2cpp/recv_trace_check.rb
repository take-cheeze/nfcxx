#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the receiver trace (tools/bc2cpp/recv_trace.rb) and its report (recv_trace_report.rb) on a synthetic
# generated-C snippet, with no mruby build:
#
#   - only generated method bodies are instrumented (a send in a shared helper is left as it was);
#   - a bare-identifier receiver of bc2cpp_send and of mrb_funcall_with_block is rewritten to record a hit;
#   - a receiver that is not a bare identifier is left as it was and counted as skipped;
#   - the header and the dump writer name the site, its kind and its receiver;
#   - the report reads a dump and counts single-class sites by kind.
#
#   ruby scripts/bc2cpp/recv_trace_check.rb

require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/recv_trace'

failures = []
check = lambda do |label, ok|
  puts format('  %-4s %s', ok ? 'ok' : 'FAIL', label)
  failures << label unless ok
end

snippet = <<~CPP
  bc2cpp_sym_names[2] = {
    "size",
    "each",
  };
  static mrb_value helper(mrb_state* M, mrb_value a) {
    return bc2cpp_send(M, a, 0, 0);
  }
  mrb_value Foo_bar_impl(mrb_state* M, mrb_value self) {
    mrb_value r1 = bc2cpp_send(M, self, 1, 0);
    mrb_value r2 = mrb_funcall_with_block(M, r1, bc2cpp_sym(M, 1), 0, NULL, r1);
    mrb_value r3 = bc2cpp_send(M, a.b, 0, 0);
    return r2;
  }
CPP

text, rows, skipped = RecvTrace.instrument(snippet, 'Sym', { 'Foo_bar_impl' => 'Foo#bar' })

puts 'instrumentation'
check.call('two sites instrumented (one send, one block call)', rows.size == 2)
check.call('the helper send is not instrumented', text.include?('  return bc2cpp_send(M, a, 0, 0);'))
check.call('send rewritten to record its receiver',
           text.include?('(bc2cpp_recv_hit_Sym(M, self, 0), bc2cpp_send)(M, self, 1, 0)'))
check.call('block call rewritten to record its receiver',
           text.include?('(bc2cpp_recv_hit_Sym(M, r1, 1), mrb_funcall_with_block)(M, r1, bc2cpp_sym(M, 1), 0, NULL, r1)'))
check.call('a non-identifier receiver is left alone', text.include?('bc2cpp_send(M, a.b, 0, 0)'))
check.call('that send is counted as skipped', skipped[:receiver_not_identifier] == 1)
check.call('rows name the method, kind and receiver of each site',
           rows[0][:method] == 'Foo#bar' && rows[0][:kind] == 'send' && rows[0][:recv] == 'self' &&
             rows[1][:kind] == 'block' && rows[1][:recv] == 'r1')
check.call('the send is named from the symbol table', rows[0][:name] == 'each' && rows[1][:name] == 'each')
check.call('the header declares the hit function and the dump writer',
           text.include?('static inline void bc2cpp_recv_hit_Sym(') && text.include?('RECV_SITE\\t%s'))

puts 'report'
dump = <<~TSV
  RECV_TRACE_SYMBOL\tSym\tsites\t2\tsites_hit\t2\thits\t30
  RECV_SITE\tSym\t0\t10\t0\tFoo#bar\tFoo_bar_impl\teach\tline8\tsend\tself
  RECV_CLASS\tSym\t0\tFoo\t0\t0\t10
  RECV_SITE\tSym\t1\t20\t0\tFoo#bar\tFoo_bar_impl\teach\tline9\tblock\tr1
  RECV_CLASS\tSym\t1\tArray\t0\t1\t15
  RECV_CLASS\tSym\t1\tHash\t0\t2\t5
TSV
out = nil
Dir.mktmpdir do |dir|
  path = File.join(dir, 'recv.txt')
  File.write(path, dump)
  out, status = Open3.capture2e('ruby', File.expand_path('recv_trace_report.rb', __dir__), path)
  check.call('report exits cleanly', status.success?)
end
check.call('report counts both kinds', out.include?('send') && out.include?('block'))
check.call('the send site is single-class', out.include?('single receiver class     1 (10 calls)'))
check.call('the block site is polymorphic (Array, Hash)', out.include?('Array 15, Hash 5'))

puts ''
if failures.empty?
  puts 'recv trace check: PASS'
else
  puts "recv trace check: FAIL (#{failures.size})"
  exit 1
end
