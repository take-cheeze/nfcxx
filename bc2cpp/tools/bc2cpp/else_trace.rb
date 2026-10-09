# frozen_string_literal: true

require 'stringio'
require_relative 'site_census'

# ELSE_TRACE: opt-in counters on the else arm of a core class-tag chain.
#
# A census site (SiteCensus) whose category is core_tag_chain_else:* and that sits
# directly under an `else {` is the by-name dispatch taken when the receiver is not
# one of the tested core classes. Off unless BC2CPP_TRACE_ELSE=1 is set; the unset
# output is byte-identical to a build without this file. Set, bc2cpp's stdout is
# rewritten after codegen (nothing in codegen reads it):
#
#   bc2cpp_send(M, rN, IDX, ARGC, ...)  ->  (bc2cpp_else_hit_SYM(M, rN, ID), bc2cpp_send)(M, rN, IDX, ARGC, ...)
#
# Only receivers that are a bare C identifier are instrumented (the receiver is
# evaluated twice, which is free only for an identifier); other chain sites are
# counted as skipped. Each binary keeps, per site, the hit count and up to
# MAX_CLASSES distinct receiver classes (real class, singleton flag, and whether the
# receiver is a kind of Array/Hash/String/Range). At exit it appends to the file named
# by BC2CPP_TRACE_ELSE_OUT, or writes to stderr when that is unset. Read it with
# scripts/bc2cpp_else_trace_report.rb.
module ElseTrace
  MAX_CLASSES = 8
  SEND_CALL = /bc2cpp_send\(M, (\w+), /
  # bit values for the kind-of mask in a CLASS row
  KINDS = { 'Array' => 1, 'Hash' => 2, 'String' => 4, 'Range' => 8 }.freeze

  module_function

  def ident(symbol)
    symbol.to_s.gsub(/\W/, '_')
  end

  # A C string literal. Control characters (the report's field separator is a tab) become
  # three-digit octal escapes: a hex escape would swallow the hex-looking text after it.
  def c_string(text)
    '"' + text.to_s.gsub(/[\\"]/) { |c| "\\#{c}" }.gsub(/[^\x20-\x7e]/) { |c| format('\\%03o', c.ord) } + '"'
  end

  # Rewrites generated C++; returns [instrumented_text, rows, skipped_counts].
  # `impls` maps a generated C function name to "Owner#name" for the report.
  def instrument(cpp, symbol, impls)
    scan = SiteCensus.scan(cpp)
    lines = scan.lines
    skipped = Hash.new(0)
    targets = []
    scan.sites.each do |s|
      next unless s[:category].start_with?('core_tag_chain_else')

      if !s[:else_arm]
        skipped[:not_directly_under_else] += 1
      elsif !lines[s[:line] - 1].match?(SEND_CALL)
        skipped[:receiver_not_identifier] += 1
      else
        targets << s
      end
    end
    rows = []
    targets.each do |s|
      i = s[:line] - 1
      recv = lines[i][SEND_CALL, 1]
      id = rows.size
      method = impls.fetch(s[:fn], nil) || "(#{s[:fn] || 'file scope'})"
      meta = [method, s[:fn], s[:name], "line#{s[:line]}", s[:category], s[:origin], recv].join("\t")
      rows << { id: id, line: s[:line], fn: s[:fn], name: s[:name], category: s[:category], origin: s[:origin],
                recv: recv, method: method, meta: meta, index: i }
      lines[i] = lines[i].sub(SEND_CALL) do
        "(bc2cpp_else_hit_#{ident(symbol)}(M, #{recv}, #{id}), bc2cpp_send)(M, #{recv}, "
      end
    end
    [header(symbol, rows) + lines.join, rows, skipped]
  end

  def header(symbol, rows)
    id = ident(symbol)
    count = [rows.size, 1].max
    meta = rows.map { |r| c_string(r[:meta]) }.join(",\n  ")
    meta = '""' if rows.empty?
    <<~CPP
      // BC2CPP_TRACE_ELSE -- see tools/bc2cpp/else_trace.rb.
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
      #define BC2CPP_ELSE_TRACE_MAX_CLASSES #{MAX_CLASSES}
      struct bc2cpp_else_cls_#{id} { struct RClass* real; int singleton; unsigned kinds; unsigned long long hits; char name[96]; };
      struct bc2cpp_else_site_#{id} { unsigned long long hits; unsigned long long overflow; unsigned ncls; struct bc2cpp_else_cls_#{id} cls[BC2CPP_ELSE_TRACE_MAX_CLASSES]; };
      static struct bc2cpp_else_site_#{id} bc2cpp_else_sites_#{id}[#{count}];
      static const char* const bc2cpp_else_meta_#{id}[#{count}] = {
        #{meta}
      };
      static inline void bc2cpp_else_hit_#{id}(mrb_state* M, mrb_value recv, unsigned site) {
        struct bc2cpp_else_site_#{id}* s = &bc2cpp_else_sites_#{id}[site];
        struct RClass* own = mrb_class(M, recv);
        int singleton = own->tt == MRB_TT_SCLASS;
        struct RClass* real = mrb_class_real(own);
        unsigned i = 0;
        s->hits++;
        while (i < s->ncls && !(s->cls[i].real == real && s->cls[i].singleton == singleton)) i++;
        if (i == s->ncls) {
          if (s->ncls == BC2CPP_ELSE_TRACE_MAX_CLASSES) { s->overflow++; return; }
          struct bc2cpp_else_cls_#{id}* c = &s->cls[s->ncls++];
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
      static void bc2cpp_else_dump_#{id}(void) {
        const char* path = getenv("BC2CPP_TRACE_ELSE_OUT");
        FILE* f = (path && *path) ? fopen(path, "a") : stderr;
        unsigned long long total = 0;
        unsigned used = 0;
        if (!f) { perror(path); return; }
        for (unsigned i = 0; i < #{rows.size}; i++)
          if (bc2cpp_else_sites_#{id}[i].hits) { total += bc2cpp_else_sites_#{id}[i].hits; used++; }
        fprintf(f, "ELSE_TRACE_SYMBOL\\t%s\\tsites\\t%u\\tsites_hit\\t%u\\thits\\t%llu\\n", "#{symbol}", (unsigned)#{rows.size}, used, total);
        for (unsigned i = 0; i < #{rows.size}; i++) {
          struct bc2cpp_else_site_#{id}* s = &bc2cpp_else_sites_#{id}[i];
          if (!s->hits) continue;
          fprintf(f, "ELSE_SITE\\t%s\\t%u\\t%llu\\t%llu\\t%s\\n", "#{symbol}", i, s->hits, s->overflow, bc2cpp_else_meta_#{id}[i]);
          for (unsigned j = 0; j < s->ncls; j++)
            fprintf(f, "ELSE_CLASS\\t%s\\t%u\\t%s\\t%d\\t%u\\t%llu\\n", "#{symbol}", i, s->cls[j].name, s->cls[j].singleton, s->cls[j].kinds, s->cls[j].hits);
        }
        if (f != stderr) fclose(f);
      }
      static const int bc2cpp_else_registered_#{id} = atexit(bc2cpp_else_dump_#{id});
    CPP
  end

  # Called from bc2cpp.rb before the first output line: stdout is held, and on a
  # clean exit written out instrumented. A failed run emits nothing extra.
  def capture_stdout(symbol, impls)
    real = $stdout
    buf = StringIO.new
    $stdout = buf
    at_exit do
      $stdout = real
      next if $!

      text, rows, skipped = instrument(buf.string, symbol, impls)
      warn "== ELSE_TRACE: #{rows.size} core-chain else sites instrumented in #{symbol} " \
           "(skipped: #{skipped.map { |k, v| "#{k} #{v}" }.join(', ').then { |s| s.empty? ? 'none' : s }}) =="
      real.write(text)
    end
  end
end
