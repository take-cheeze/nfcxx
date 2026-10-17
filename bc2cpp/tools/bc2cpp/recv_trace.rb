# frozen_string_literal: true

require 'stringio'
require_relative 'site_census'

# RECV_TRACE: opt-in receiver counters on every by-name send and block call of the generated method
# bodies. Off unless BC2CPP_TRACE_RECV=1 is set; the unset output is byte-identical to a build without
# this file. Set, bc2cpp's stdout is rewritten after codegen (nothing in codegen reads it):
#
#   bc2cpp_send(M, rN, IDX, ARGC, ...)                 ->  (bc2cpp_recv_hit_SYM(M, rN, ID), bc2cpp_send)(M, rN, IDX, ...)
#   mrb_funcall_with_block(M, rN, SYM, ARGC, ARGV, B)  ->  (bc2cpp_recv_hit_SYM(M, rN, ID), mrb_funcall_with_block)(M, rN, ...)
#
# Only receivers that are a bare C identifier are instrumented (the receiver is evaluated twice, which
# is free only for an identifier); other sites are counted as skipped. Each binary keeps, per site, the
# hit count and up to MAX_CLASSES distinct receiver classes (real class, singleton flag, and whether the
# receiver is a kind of Array/Hash/String/Range). At exit it appends to the file named by
# BC2CPP_TRACE_RECV_OUT, or writes to stderr when that is unset. Read it with
# scripts/bc2cpp/recv_trace_report.rb. Not combinable with BC2CPP_TRACE_ELSE: both rewrite the send.
module RecvTrace
  MAX_CLASSES = 8
  CALL = /bc2cpp_send\(M, (?<srecv>\w+), (?<sidx>\d+),|mrb_funcall_with_block\(M, (?<brecv>\w+), (?:bc2cpp_sym\(M, (?<bidx>\d+)\)|[^,]+),/
  KINDS = { 'Array' => 1, 'Hash' => 2, 'String' => 4, 'Range' => 8 }.freeze

  module_function

  def ident(symbol)
    symbol.to_s.gsub(/\W/, '_')
  end

  def c_string(text)
    '"' + text.to_s.gsub(/[\\"]/) { |c| "\\#{c}" }.gsub(/[^\x20-\x7e]/) { |c| format('\\%03o', c.ord) } + '"'
  end

  # Rewrites generated C++; returns [instrumented_text, rows, skipped_counts].
  # `impls` maps a generated C function name to "Owner#name" for the report.
  def instrument(cpp, symbol, impls)
    lines = cpp.lines
    names = SiteCensus.sym_names(cpp)
    first_method = SiteCensus.first_method_line(lines)
    skipped = Hash.new(0)
    rows = []
    cur = nil
    lines.each_with_index do |l, i|
      cur = SiteCensus.fn_name(l) || cur
      next if first_method.nil? || i < first_method
      next unless l.include?('bc2cpp_send(M, ') || l.include?('mrb_funcall_with_block(M, ')

      lines[i] = l.gsub(CALL) do
        m = Regexp.last_match
        send_form = !m[:srecv].nil?
        recv = send_form ? m[:srecv] : m[:brecv]
        index = send_form ? m[:sidx] : m[:bidx]
        name = index ? names[index.to_i] : '(dynamic)'
        id = rows.size
        method = impls.fetch(cur, nil) || "(#{cur || 'file scope'})"
        kind = send_form ? 'send' : 'block'
        meta = [method, cur, name, "line#{i + 1}", kind, recv].join("\t")
        rows << { id: id, method: method, fn: cur, name: name, line: i + 1, kind: kind, recv: recv, meta: meta }
        head = send_form ? 'bc2cpp_send' : 'mrb_funcall_with_block'
        "(bc2cpp_recv_hit_#{ident(symbol)}(M, #{recv}, #{id}), #{head})" + m[0][head.size..]
      end
    end
    # Sends left in the generated bodies after the rewrite are the ones whose receiver is not a bare identifier.
    generated = lines.drop(first_method.to_i)
    skipped[:receiver_not_identifier] = generated.sum { |l| l.scan(/bc2cpp_send\(M, |mrb_funcall_with_block\(M, /).size }
    [header(symbol, rows) + lines.join, rows, skipped]
  end

  def header(symbol, rows)
    id = ident(symbol)
    count = [rows.size, 1].max
    meta = rows.map { |r| c_string(r[:meta]) }.join(",\n  ")
    meta = '""' if rows.empty?
    <<~CPP
      // BC2CPP_TRACE_RECV -- see tools/bc2cpp/recv_trace.rb.
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <mruby.h>
      #include <mruby/class.h>
      #include <mruby/value.h>
      #include <mruby/array.h>
      #include <mruby/hash.h>
      #include <mruby/string.h>
      #include <mruby/range.h>
      #define BC2CPP_RECV_TRACE_MAX_CLASSES #{MAX_CLASSES}
      struct bc2cpp_recv_cls_#{id} { struct RClass* real; int singleton; unsigned kinds; unsigned long long hits; char name[96]; };
      struct bc2cpp_recv_site_#{id} { unsigned long long hits; unsigned long long overflow; unsigned ncls; struct bc2cpp_recv_cls_#{id} cls[BC2CPP_RECV_TRACE_MAX_CLASSES]; };
      static struct bc2cpp_recv_site_#{id} bc2cpp_recv_sites_#{id}[#{count}];
      static const char* const bc2cpp_recv_meta_#{id}[#{count}] = {
        #{meta}
      };
      static inline void bc2cpp_recv_hit_#{id}(mrb_state* M, mrb_value recv, unsigned site) {
        struct bc2cpp_recv_site_#{id}* s = &bc2cpp_recv_sites_#{id}[site];
        struct RClass* own = mrb_class(M, recv);
        int singleton = own->tt == MRB_TT_SCLASS;
        struct RClass* real = mrb_class_real(own);
        unsigned i = 0;
        s->hits++;
        while (i < s->ncls && !(s->cls[i].real == real && s->cls[i].singleton == singleton)) i++;
        if (i == s->ncls) {
          if (s->ncls == BC2CPP_RECV_TRACE_MAX_CLASSES) { s->overflow++; return; }
          struct bc2cpp_recv_cls_#{id}* c = &s->cls[s->ncls++];
          const char* n = mrb_obj_classname(M, recv);
          c->real = real;
          c->singleton = singleton;
          c->kinds = (mrb_obj_is_kind_of(M, recv, M->array_class) ? 1u : 0u) |
                     (mrb_obj_is_kind_of(M, recv, M->hash_class) ? 2u : 0u) |
                     (mrb_obj_is_kind_of(M, recv, M->string_class) ? 4u : 0u) |
                     (mrb_obj_is_kind_of(M, recv, M->range_class) ? 8u : 0u);
          strncpy(c->name, n ? n : "?", sizeof c->name - 1);
          c->name[sizeof c->name - 1] = 0;
          c->hits = 0;
          i = s->ncls - 1;
        }
        s->cls[i].hits++;
      }
      static void bc2cpp_recv_dump_#{id}(void) {
        const char* path = getenv("BC2CPP_TRACE_RECV_OUT");
        FILE* f = (path && *path) ? fopen(path, "a") : stderr;
        unsigned long long total = 0;
        unsigned used = 0;
        if (!f) { perror(path); return; }
        for (unsigned i = 0; i < #{rows.size}; i++)
          if (bc2cpp_recv_sites_#{id}[i].hits) { total += bc2cpp_recv_sites_#{id}[i].hits; used++; }
        fprintf(f, "RECV_TRACE_SYMBOL\\t%s\\tsites\\t%u\\tsites_hit\\t%u\\thits\\t%llu\\n", "#{symbol}", (unsigned)#{rows.size}, used, total);
        for (unsigned i = 0; i < #{rows.size}; i++) {
          struct bc2cpp_recv_site_#{id}* s = &bc2cpp_recv_sites_#{id}[i];
          if (!s->hits) continue;
          fprintf(f, "RECV_SITE\\t%s\\t%u\\t%llu\\t%llu\\t%s\\n", "#{symbol}", i, s->hits, s->overflow, bc2cpp_recv_meta_#{id}[i]);
          for (unsigned j = 0; j < s->ncls; j++)
            fprintf(f, "RECV_CLASS\\t%s\\t%u\\t%s\\t%d\\t%u\\t%llu\\n", "#{symbol}", i, s->cls[j].name, s->cls[j].singleton, s->cls[j].kinds, s->cls[j].hits);
        }
        if (f != stderr) fclose(f);
      }
      static const int bc2cpp_recv_registered_#{id} = atexit(bc2cpp_recv_dump_#{id});
    CPP
  end

  # Called from bc2cpp.rb before the first output line: stdout is held, and on a clean exit written
  # out instrumented. A failed run emits nothing extra.
  def capture_stdout(symbol, impls)
    real = $stdout
    buf = StringIO.new
    $stdout = buf
    at_exit do
      $stdout = real
      next if $!

      text, rows, skipped = instrument(buf.string, symbol, impls)
      warn "== RECV_TRACE: #{rows.size} by-name sites instrumented in #{symbol} " \
           "(skipped: #{skipped.map { |k, v| "#{k} #{v}" }.join(', ').then { |s| s.empty? ? 'none' : s }}) =="
      real.write(text)
    end
  end
end
