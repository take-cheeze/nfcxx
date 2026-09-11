# Single source of truth for every bc2cpp-generated gem's own target
# owners and OUT_SYMBOL -- both mruby-lcf-compiled/mrbgem.rake and
# mruby-rpg2k-compiled/mrbgem.rake `require` this instead of hardcoding
# each other's owner list (real drift risk otherwise) or `target_owners`
# duplicated between files. `closed_world_mrblib_srcs` below (mirroring
# `core_native_srcs`) is the same fix applied to the whole-program mrblib
# source set every compiled gem's own registry-building bc2cpp.rb
# invocation feeds in -- see its own comment for why this one was a real,
# checked structural-soundness question in its own right (docs/adr/0139's
# own cross-gem-devirtualization-soundness follow-up), not just a style
# nit.
#
# Also what makes cross-gem devirtualization (docs/adr/0139's own
# follow-up) possible at all: each mrbgem.rake computes its own
# OTHER_OWNERS/OTHER_DECLS_HEADER from every *other* entry here, so a
# devirtualized call from one compiled gem into another's target class can
# reference a real, externally-linked _impl declared via that other gem's
# own *_decls.h (see bc2cpp.rb's own emit_decls_header comment) -- without
# either gem's own bc2cpp codegen step needing to read the other's
# generated output (that would be a circular Rake dependency; only the
# final C++ compile of register.cxx needs both gems' generated files to
# already exist, which mrbgem.rake wires as a `file` dependency, not this).
BC2CPP_COMPILED_GEMS = {
  'mruby-lcf-compiled' => {
    # LCF::MoveCommand (docs/adr/0139's own follow-up, mruby-lcf/mrblib/
    # lcf.rb) -- one decoded RPG2000 move-route command (a command id plus
    # optional string/integer parameters). Its own #initialize is the
    # ONLY real bytecode-defined method on this class at all (attr_reader
    # :command_id, :parameter_string, :parameter_a, :parameter_b,
    # :parameter_c stays native/uncompiled, as always) and it compiles
    # clean: 5 purely mandatory arguments, no super, no block, needing
    # zero new bc2cpp.rb opcode work. Confirmed for real against the
    # actual diagnostic, not just trusted from its own pre-existing
    # `# bc2cpp: (fixnum, , fixnum, fixnum, fixnum)` magic-comment
    # annotation: the real `== compiled entry points ==` listing shows
    # `LCF__MoveCommand_initialize / LCF__MoveCommand_initialize_impl
    # (LCF::MoveCommand#initialize, arity 5) [private -- use
    # mrb_define_private_method, not mrb_define_method]`.
    #
    # Does NOT get any real RData embedding, despite @command_id/
    # @parameter_a/@parameter_b/@parameter_c all being provably Fixnum --
    # a later-found-and-fixed drift this round's own dedicated bug-hunt
    # sweep caught: this class's own bare `attr_reader :command_id, ...,
    # :parameter_a, :parameter_b, :parameter_c` is the exact same
    # native-accessor/embedded-ivar collision shape as LCF::EventCommand's
    # own (below) and the four already-shipped Game:: classes
    # bc2cpp.rb's `natively_exposed?`/`drop_unsafe_embeddings` fix exists
    # to catch (docs/adr/0139's own eighth-severe-bug follow-up) -- but
    # that round's own fix never got re-checked against this class, even
    # though MoveCommand was already a shipped embedding target sitting
    # in the very same file the round touched. Re-running the real
    # whole-program diagnostic against the *current* bc2cpp.rb (this
    # round's own sweep) confirms LCF::MoveCommand no longer appears in
    # bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic at
    # all, and the regenerated #initialize body writes every one of its
    # five ivars via a plain mrb_iv_set, same as every other
    # (non-embedding) compiled #initialize in this gem -- confirmed
    # directly against the real generated lcf_compiled_gen.cpp.
    # mruby-lcf-compiled/src/register.cxx's own hand-written
    # `MRB_SET_INSTANCE_TT(move_command, ...)` call (and this comment,
    # both describing the pre-fix behavior) were stale as a result --
    # fixed to match by removing the call and correcting the comment; see
    # that file's own MoveCommand comment for the full writeup, including
    # why the drift was confirmed harmless at the mruby-core level (no
    # compiled code ever touched the never-allocated RData payload) rather
    # than a second live embedding bug. :command_id/:parameter_a/
    # :parameter_b/:parameter_c/:parameter_string are all POLY in the
    # whole-program registry (2 defs each: this class and the real,
    # separate Game::MoveCommand, mruby-rpg2k/mrblib/game.rb) --
    # correctly has no bearing on registering this class's own methods,
    # only on whether some *other* call site could devirtualize into one
    # of them. #initialize is forced private by mruby's own interpreter
    # regardless of source, so it needs mrb_define_private_method, not
    # mrb_define_method -- confirmed directly against the real
    # diagnostic's own listing above, which flags it accordingly.
    #
    # LCF::EventCommand (docs/adr/0139) joins the original LCF::File-family
    # targets -- one decoded RPG2000 event-page/common-event/move-route
    # command (code, indent, string, integer parameters). Its own
    # #initialize already carried a real `# bc2cpp: (fixnum, fixnum, , )`
    # annotation (mruby-lcf/mrblib/lcf.rb) from an earlier round's dynamic
    # profiling pass, but was never actually added as a compiled owner
    # until now. #initialize is pure mandatory-arity (4 required args, no
    # super, no block) and compiles clean, and both #initialize and #param
    # are registered below -- but checked directly against the real
    # generated output rather than trusted from the annotation alone,
    # this class does NOT actually get any real RData embedding, despite
    # @code/@indent both being provably Fixnum (per the annotation and the
    # whole-program EMBED diagnostic): this class's own `attr_reader
    # :code, :indent, :string, :parameters` (mruby-lcf/mrblib/lcf.rb)
    # covers the exact same two ivars, and this round's own dedicated
    # bug-hunt (see this file's own top comment / mruby-rpg2k-compiled/
    # src/register.cxx's own top comment for the full writeup) found that
    # a plain `attr_reader` for an embedded ivar's own bare name is a
    # real, live correctness bug -- its native `mrb_iv_get` implementation
    # never sees a value this class's own SETIV codegen wrote into an
    # embedded RData struct field instead, so `.code`/`.indent` would
    # silently return `nil` on every real compiled instance. bc2cpp.rb's
    # drop_unsafe_embeddings now refuses to embed any ivar that collides
    # this way, so `LCF::EventCommand` does not appear in bc2cpp's own
    # "classes needing MRB_SET_INSTANCE_TT" diagnostic, no
    # `LCF__EventCommand_ivars` struct is generated, and #initialize's own
    # compiled body writes @code/@indent/@string/@parameters via plain
    # `mrb_iv_set`, exactly like every other (non-embedding) compiled
    # #initialize in this gem.
    #
    # LCF::Tree (mruby-lcf/mrblib/lcf.rb, right above LCF::EventCommand) --
    # one decoded map-tree section: which map is currently selected plus the
    # flat list of every map id in tree order (LCF::MapTree's own `:tree`
    # section, read by both #read_section's `:Tree` case and #to_rb's own
    # `:Tree` schema-type branch). #initialize is the ONLY real
    # bytecode-defined method on this class (`attr_reader :selected_id,
    # :maps` stays native/uncompiled, as always) and it compiles clean: 2
    # purely mandatory arguments, no super, no block -- confirmed directly
    # against the real `== compiled entry points ==` listing:
    # `LCF__Tree_initialize / LCF__Tree_initialize_impl (LCF::Tree#initialize,
    # arity 2) [private -- use mrb_define_private_method, not
    # mrb_define_method]`.
    #
    # Unlike LCF::EventCommand right above, this class carries no `# bc2cpp:`
    # type annotation at all, and neither @selected_id nor @maps is ever
    # traceable to a literal or an annotated argument -- both show up only
    # in the real diagnostic's own `report_annotation_candidates` list
    # (`CANDIDATE LCF::Tree#initialize, arg 1/2 -> @selected_id` / `arg 2/2
    # -> @maps`), never as an EMBED proposal, so neither ivar is even a
    # candidate for RData embedding today, independent of the
    # `attr_reader`/embedded-ivar collision this round's own sibling
    # LCF::EventCommand target found and fixed. Checked one step further
    # anyway, per this project's own established discipline of confirming
    # rather than assuming: temporarily annotating this class's own
    # #initialize `# bc2cpp: (fixnum, )` (matching @selected_id's real,
    # always-Fixnum construction sites -- LCF.read_section's own `:Tree`
    # case and LCF#to_rb's own `:Tree` branch both pass a `read_ber` result)
    # and re-running the real diagnostic confirms `LCF::Tree` still does NOT
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" list, and
    # the regenerated `LCF__Tree_initialize_impl` still writes `@selected_id`
    # via plain `mrb_iv_set`, never `mrb_data_init` -- i.e. this class's own
    # `attr_reader :selected_id` WOULD have collided exactly the same way
    # LCF::EventCommand's `attr_reader :code, :indent` did, and
    # `natively_exposed?` correctly suppresses it. That experimental
    # annotation was reverted before this commit; the real, shipped
    # `mruby-lcf/mrblib/lcf.rb` carries no annotation on this class, so the
    # point is moot today for a second, independent reason (no type
    # information reaches the embedding pass at all), but confirmed live
    # rather than assumed regardless. @maps (an Array, from a schema-decoded
    # id list, never Fixnum/Symbol) was never going to embed either way.
    #
    # LCF::Sections (docs/adr/0139's own follow-up, mruby-lcf/mrblib/
    # lcf.rb) -- holds the sequential sections of a multi-section file
    # (currently only LCF::MapTree's own Array-shaped schema: a
    # map-properties table plus the tree order and initial party/vehicle
    # positions), constructed exactly once, in LCF::File#initialize
    # (mruby-lcf/mrblib/lcf_file.rb) -- confirmed no subclass and no other
    # construction site exist anywhere in this codebase (grepped the
    # whole tree), the same construction-site-safety check this project's
    # own established discipline already applies to every embedding
    # candidate. All 4 of its own real bytecode-defined methods compile
    # clean, needing zero new bc2cpp.rb opcode work: #initialize (2 plain
    # Hash/Array literal SETIVs, no arguments at all), #add (a Hash
    # `[]=`/Array `#push` pair), #key? (a POLY `@by_name.key?` forward,
    # `mrb_funcall`), and #[] -- confirmed directly against the real
    # generated output (`== compiled entry points ==` lists all four:
    # `LCF__Sections_initialize`/`_key_`/`___`/`_add`), not assumed from
    # the class's small size. #[]'s own `idx.is_a? Symbol` guard needed no
    # new opcode work either: it's an ordinary POLY SEND into the native
    # (non-bytecode) `is_a?`, compiling to the exact same generic
    # `mrb_funcall(M, r3, "is_a?", 1, r4)` fallback every other already-
    # shipped `x.is_a? Foo` guard in this codebase already takes (a GETCONST
    # scope-chain lookup for `Symbol` followed by the call), and the
    # `if (!mrb_test(r3)) goto L28;` that follows it is the same already-
    # supported JMPNOT branch shape every other compiled guard clause here
    # already uses -- not a conditional/branch opcode this compiler needed
    # to special-case at all. #method_missing/#respond_to_missing? are out
    # of scope, same as every other method_missing-using class in this
    # codebase (confirmed in the real diagnostic's own `== skipped
    # (unsupported, left on the interpreter) ==` list, not assumed from
    # the name alone). @by_name/@list are a Hash and an Array respectively --
    # never Fixnum/Symbol -- so IvarLayout correctly infers nothing
    # embeddable here at all; confirmed directly, this class never
    # appears in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic (no attr_reader/writer/accessor on this class either, so
    # there is nothing for drop_unsafe_embeddings to have to reject even
    # if there were something to embed).
    # LCF::Array1D (mruby-lcf/mrblib/lcf.rb, right above LCF::Array2D) -- the
    # sequential chunk-id -> raw-bytes record every LCF::File-family object
    # (Database, MapTree/MapUnit's own sub-records, SaveData's own actors/
    # party/etc.) actually decodes through: an id-keyed list of on-disk
    # chunks read off a real .lmt/.lmu/.ldb/.lsd stream, plus the schema that
    # gives each chunk id a type/name. A genuinely more complex class than
    # LCF::Tree/LCF::Sections above -- 11 real bytecode-defined methods, not
    # 1-4 -- so this entry documents each one instead of the class as a
    # whole, matching this project's own established per-method rigor
    # wherever a class is a mix of compiling and non-compiling methods.
    #
    # 5 of its own 11 real bytecode-defined methods compile clean, needing
    # zero new bc2cpp.rb opcode work, confirmed directly against the real
    # `== compiled entry points ==` listing rather than assumed from arity
    # alone:
    #   LCF__Array1D___         (LCF::Array1D#[],            arity 1)
    #   LCF__Array1D_key_       (LCF::Array1D#key?,          arity 1)
    #   LCF__Array1D_int16_values (LCF::Array1D#int16_values, arity 1)
    #   LCF__Array1D_delete     (LCF::Array1D#delete,        arity 1)
    #   LCF__Array1D____        (LCF::Array1D#[]=,           arity 2)
    # All five are public, pure mandatory arity, no super, no block --
    # #[] resolves a Symbol key via #sym2idx then does a Hash/Array-shaped
    # GETIDX plus a decoded-value cache lookup (`@decoded`); #key?/#delete
    # are plain @data GETIDX/nil-check/SETIDX; #int16_values is a single
    # `#unpack('s<*')` POLY send; #[]= is an elem-lookup plus an `elsif`
    # chain, all already-supported shapes.
    #
    # 6 more real methods stay interpreted, each confirmed against its own
    # real `#error` marker (a plain SKIP_UNSUPPORTED=1 run only lists a
    # method as skipped; re-running with SKIP_UNSUPPORTED=0 was needed to
    # see *why*, one call this round's own brief specifically required
    # rather than guessing from the Ruby source shape alone):
    #   - #initialize(s, schema): a real `loop do ... end` (reading chunks
    #     off the StringIO one BER-id/BER-len/read(len) triple at a time
    #     until EOF or a 0 id). This is NOT the already-supported JMP/
    #     JMPNOT back-edge shape a plain `while`/`until` keyword loop
    #     compiles to elsewhere in this codebase (checked directly, not
    #     assumed from the source shape -- this project's own brief
    #     specifically asked this be confirmed rather than guessed):
    #     `loop` is an ordinary Kernel#loop *method call* taking a block,
    #     so mrbc emits it as BLOCK+SSENDB, and the real generated body
    #     confirms it: `#error unhandled opcode BLOCK` / `#error unhandled
    #     opcode SSENDB` are the only two errors in an otherwise-compiling
    #     body (the StringIO-conversion guard and both @data/@schema SETIVs
    #     above the loop all compile fine on their own). Same established
    #     out-of-scope shape as every other genuine-Ruby-block method this
    #     ADR already documents elsewhere, not a new gap.
    #   - #to_lcf(terminate = true): non-mandatory arity (one optional
    #     argument), the same established gap as every other optional-arg
    #     method in this codebase -- confirmed via its own real `#error
    #     LCF::Array1D#to_lcf has non-mandatory arguments` marker. (Its own
    #     `@data.each_with_index do |v, idx| ... end` body would have hit a
    #     second, independent BLOCK/SENDB gap even past the arity one, the
    #     same shape #initialize's own loop hits above, but the arity check
    #     runs first and is reported as the reason.)
    #   - #method_missing(sym, *args): non-mandatory arity (a rest
    #     argument) -- confirmed via its own `#error ... has non-mandatory
    #     arguments` marker, same as every other method_missing on a class
    #     in this codebase.
    #   - #respond_to_missing?(sym, include_private = false): non-mandatory
    #     arity (one optional argument) -- confirmed via its own `#error
    #     ... has non-mandatory arguments` marker, same shape as #to_lcf.
    #   - #sym2idx (private): confirmed via its own real generated body,
    #     not just assumed from the doc comment above it mentioning
    #     `.each` -- `LCF.elements_of(@schema).each { |k, e| ... }` compiles
    #     everything around it fine (the @sym2idx memoization checks, the
    #     schema Array/Hash/POLY-fallback GETIDX, the final @sym2idx
    #     SETIDX) but hits the exact same `#error unhandled opcode BLOCK` /
    #     `#error unhandled opcode SENDB` pair #initialize's own loop does,
    #     confirmed directly against its own real generated function body.
    #   - `attr_reader :schema` stays native/uncompiled, as always -- not a
    #     real bytecode-defined method at all.
    #
    # Embedding: NONE, confirmed directly against the real diagnostic --
    # `LCF::Array1D` never appears in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" listing, so no MRB_SET_INSTANCE_TT call belongs
    # in this class's own registration block. `@data` (built via `@data[idx]
    # = s.read(len)` inside #initialize's own uncompiled loop -- an Array of
    # Strings) and `@schema` (the constructor's own second argument, a Hash
    # per its pre-existing `# bc2cpp: (, Hash)` annotation) are never
    # Fixnum/Symbol, so IvarLayout correctly infers nothing embeddable here
    # regardless of #initialize itself never compiling (a real, mandatory
    # `drop_unsafe_embeddings` gate this class's own uncompiled #initialize
    # would fail anyway, since embedding only ever happens through a
    # compiling constructor's own SETIV codegen). `attr_reader :schema`
    # would matter here the same way it did for LCF::EventCommand/
    # LCF::MoveCommand's own attr_readers above if @schema were ever a
    # Fixnum/Symbol embedding candidate -- it isn't, so `natively_exposed?`
    # never even needs to act on this class.
    # LCF::Array2D (mruby-lcf/mrblib/lcf.rb, right below LCF::Array1D) -- the
    # id-keyed table of rows every LCF::File-family object's own project-map
    # tree / database item/actor/skill/... list actually decodes through:
    # each row is itself an Array1D chunk stream, and this class only tracks
    # where each row's raw byte span sits until something actually reads it.
    # A genuinely different method shape from Array1D right above it (not
    # its structural twin, despite both being schema-driven, chunk-id-keyed
    # containers) -- confirmed directly by reading the real source rather
    # than assumed: 6 real bytecode-defined methods, not 11, and neither
    # #method_missing nor #respond_to_missing? exists on this class at all
    # (Array2D is indexed purely by integer row id, with no per-field
    # symbolic accessor to dispatch through -- unlike Array1D's own
    # per-chunk-id + schema-driven symbolic-field lookup).
    #
    # 2 of its own 6 real bytecode-defined methods compile clean, needing
    # zero new bc2cpp.rb opcode work, confirmed directly against the real
    # `== compiled entry points ==` listing:
    #   LCF__Array2D___         (LCF::Array2D#[],  arity 1)
    #   LCF__Array2D____        (LCF::Array2D#[]=, arity 2)
    # Both public, pure mandatory arity, no super, no block. #[] lazily
    # decodes (and in-place caches) a row's raw byte span into a real
    # Array1D on first access (`Array1D.new(entry, @schema)`, an ordinary
    # POLY `:new` send into a sibling compiled class plus a plain
    # `@data[idx] =` SETIDX) and returns the row unchanged when it is
    # already decoded (or absent); #[]= is a bare `@data[idx] = entry`
    # SETIDX with no schema/elsif logic at all (simpler than Array1D's own
    # #[]=, which does have one).
    #
    # 4 more real methods stay interpreted, each confirmed against its own
    # real `#error` marker with SKIP_UNSUPPORTED=0 (not guessed from the
    # Ruby source shape):
    #   - #initialize(s, schema): NOT the same on-disk decode shape as
    #     Array1D#initialize's own id/len/bytes `loop`, confirmed directly
    #     by reading the source -- Array2D's own header is a single
    #     BER-encoded row count, then one BER row-id per entry, each
    #     followed by one *undelimited* Array1D-shaped chunk stream (a
    #     nested id/len/bytes run terminated by chunk-id 0, scanned but not
    #     decoded -- see #read_row_bytes below). The count is consumed via
    #     `(0...LCF.read_ber(s)).each do ... end`, a `Range#each` method
    #     call taking a block -- the exact same BLOCK/SENDB opcode pair
    #     Array1D#initialize's own `loop` (a `Kernel#loop` method call
    #     taking a block) hits, just a different block-taking method
    #     producing it: `#error unhandled opcode BLOCK` / `#error unhandled
    #     opcode SENDB` are the only two errors in an otherwise-compiling
    #     body (the StringIO-conversion guard, the early `return if
    #     s.eof?`, and both @data/@schema SETIVs above the loop all compile
    #     fine on their own).
    #   - #each: no arguments (unlike Array1D, which has no #each at all),
    #     but `@data.size.times do |i| ... end` is a third block-taking
    #     method call hitting the exact same `#error unhandled opcode
    #     BLOCK` / `#error unhandled opcode SENDB` pair -- confirmed
    #     directly against its own real generated body, not assumed from
    #     the `.times do` shape alone. `include Enumerable` (a class-body
    #     level call, not a per-instance bytecode method) is unaffected
    #     either way.
    #   - #to_lcf: no arguments at all (unlike Array1D#to_lcf's own single
    #     optional `terminate` argument, which fails on arity before its
    #     own block is ever reached) -- confirmed via its own real body,
    #     which hits the BLOCK/SENDB pair TWICE, independently, once for
    #     `@data.each_with_index { |v, i| ... }` (collecting defined row
    #     ids) and again for `ids.each do |i| ... end` (writing each row).
    #   - #read_row_bytes (private): a real `loop do ... end`, the
    #     identical shape (and identical `#error unhandled opcode BLOCK` /
    #     `#error unhandled opcode SSENDB` pair) as Array1D#initialize's
    #     own loop and Array1D#sym2idx's own `.each` -- confirmed directly
    #     against its own real generated body, not inferred from the
    #     doc comment above it describing the scan.
    #
    # Embedding: NONE, confirmed directly against the real diagnostic --
    # `LCF::Array2D` never appears in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" listing, so no MRB_SET_INSTANCE_TT call belongs
    # in this class's own registration block. @data (built as `@data[idx]
    # = read_row_bytes(s)` inside #initialize's own uncompiled loop -- an
    # Array of Strings, later replaced element-by-element with Array1D
    # instances by #[]'s own lazy-decode SETIDX) and @schema (the
    # constructor's own second argument, a Hash) are never Fixnum/Symbol,
    # so IvarLayout correctly infers nothing embeddable here, independent
    # of #initialize itself never compiling (same mandatory
    # drop_unsafe_embeddings gate every other non-compiling-#initialize
    # target in this ADR already documents: embedding only ever happens
    # through a compiling constructor's own SETIV codegen). This class
    # carries no `attr_reader`/`attr_writer`/`attr_accessor` at all
    # (unlike Array1D's own `attr_reader :schema`), so there is no native-
    # accessor/embedded-ivar collision surface here for
    # `natively_exposed?` to even need to act on -- confirmed by this
    # class's own absence from the real diagnostic's `report_
    # annotation_candidates` EMBED-proposal output, not merely inferred
    # from the lack of an attr_reader.
    #
    # LCF::File#[]/#[]= (mruby-lcf/mrblib/lcf_file.rb): the LCF::Array1D
    # entry above's own writeup flagged, in passing, that these two already
    # compile clean today (real `LCF__File___`/`LCF__File____` entry points
    # in the diagnostic) despite this file's own top comment and
    # mruby-lcf-compiled/mrbgem.rake's comment both still claiming the whole
    # LCF::File-family `#[]`/`#[]=` stays interpreted -- an open question a
    # later round resolved by re-checking directly against the real
    # diagnostic rather than trusting either stale comment. Confirmed real,
    # not stale documentation of a genuine limitation: both compile to the
    # same generic Array/Hash-fastpath-plus-POLY-`mrb_funcall`-fallback
    # shape LCF::Array1D's/LCF::Sections's own already-registered `#[]`/
    # `#[]=` use, dispatched against `@root` (LCF::File#initialize always
    # sets it to an LCF::Sections or an LCF.const_get(schema[:type])
    # instance, never a real Array/Hash, so the fallback branch always
    # fires and correctly dispatches dynamically to whichever class @root
    # actually is at runtime -- no devirtualization of `@root` itself is
    # involved, so subclass identity, Database vs. MapTree vs. MapUnit vs.
    # SaveData, never matters here). Now registered in
    # mruby-lcf-compiled/src/register.cxx (see that file's own comment for
    # the full writeup); this was a real, previously-missed coverage
    # opportunity, not a case where the tool ever produced something
    # unsafe.
    owners: %w[LCF::File LCF::Database LCF::MapTree LCF::MapUnit LCF::SaveData
               LCF::MoveCommand LCF::EventCommand LCF::Tree LCF::Sections
               LCF::Array1D LCF::Array2D],
    out_symbol: 'lcf_compiled',
  },
  'mruby-rpg2k-compiled' => {
    # Game::EnemyAction (docs/adr/0139) added alongside the original
    # Game::Picture target -- both real mruby-rpg2k classes, so both live
    # in this one gem rather than a separate one per class. Game::Screen
    # and RPG2k::Window (docs/adr/0139's own array-literal/LOADSELF/MUL/
    # AREF opcode follow-up) join them here too. Screen's own #initialize
    # takes zero arguments and compiles clean, so it's the first shipped
    # target whose ivars actually get embedded into a real RData struct
    # (see register.cxx's own MRB_SET_INSTANCE_TT comment); Window's own
    # #initialize stays interpreted (optional args), same as Picture's.
    # Game::Transition (docs/adr/0139's own follow-up) is the second real
    # target with an embedding #initialize -- purely mandatory-arity (5
    # required args, no opts), the same shape as Screen's. Game::Actor
    # (docs/adr/0139's own GETIDX/SETIDX/GETGV opcode follow-up) is the
    # biggest real target at that time -- 76 of its own real bytecode-
    # defined methods (up from 75 -- #set_exp, unblocked by SUBILV, a
    # Game::Party-round opcode, see below) across mruby-rpg2k/mrblib/
    # game.rb and game/battle_support.rb's own reopening of the class; its
    # own #initialize stays interpreted (BLOCK/SENDB/GETIDX), same shape as
    # Picture's/Window's, so its own provably-Fixnum ivars stay unembedded
    # too -- confirmed for real after fixing a real, live memory-safety bug
    # in bc2cpp.rb's own drop_unsafe_embeddings (arity-only, not compile-
    # clean-checked, had let them through anyway; see register.cxx's own
    # top comment for the real fix and its own confirmed-safe
    # re-verification).
    #
    # Game::Party (docs/adr/0139's own Game::Party follow-up) -- party-wide
    # item/skill usability rules, equip/swap logic, skill damage formulas,
    # state/status application, battle placement. 85 of its own 128 real
    # bytecode-defined methods, needing six more new opcodes (NOP, ADDILV/
    # SUBILV, RANGE_INC/RANGE_EXC, RETURN_BLK -- see bc2cpp.rb's own
    # compile_insn comments on each). Its own #initialize stays interpreted
    # (two optional arguments, `ids = nil, roster = nil`), same shape as
    # Picture's/Window's/Actor's, so its own two provably-Fixnum ivars
    # (@gold, @revision) stay unembedded too.
    #
    # A dedicated later round re-checked mruby-rpg2k/mrblib/game/
    # battle_support.rb's own separate reopening of both Game::Actor and
    # Game::Party (docs/adr/0139's own Game::Actor/Game::Party
    # battle_support.rb-coverage follow-up) against the real diagnostic,
    # not just against what register.cxx's own comments already claimed.
    # Conclusion up front: zero registration changes -- every method that
    # reopening defines and this compiler can actually compile was already
    # registered; what this round found and fixed were two real, confirmed
    # documentation gaps in register.cxx's own comments (see that file's
    # own Game::Actor/Game::Party comment blocks for the corrected text):
    #
    #   - battle_support.rb's own `class Actor` reopening defines 13 real
    #     methods, not the 9 an earlier round's own comment named -- the
    #     other 4 (#states=, #prevents_critical?, #state_resist_mul,
    #     #physical_evasion_up?) were never registered (correctly -- each
    #     ends in a genuine Ruby block, confirmed against its own real
    #     `#error unhandled opcode BLOCK`/`SENDB` marker with
    #     SKIP_UNSUPPORTED=0), but that earlier comment never said so, as
    #     if the reopening had nothing left over at all.
    #   - battle_support.rb's own `class Party` reopening's own comment
    #     mistakenly filed `#stat_mode` under "the battle_support.rb
    #     reopening's own" block-using methods -- it is not part of that
    #     reopening at all; it is `Game::Party#stat_mode` in game.rb's own
    #     main ~2,300-line class body (`def stat_mode`, game.rb line
    #     5716), which also ends in a genuine Ruby block and so also stays
    #     interpreted, just for an unrelated reason having nothing to do
    #     with this second reopening. `#battle_skill_command` (this
    #     reopening's own real, keyword-argument-blocked method, `free:
    #     false`) was already correctly named elsewhere in that same
    #     comment, in the non-mandatory-arity group where its own real
    #     `#error ... has non-mandatory arguments` marker puts it -- not a
    #     second gap, despite looking related at a glance.
    #
    # Re-ran the real `bc2cpp.rb` diagnostic end to end for this
    # (`ONLY_OWNERS`/`OTHER_OWNERS`/`NATIVE_SRCS`/`SKIP_UNSUPPORTED`
    # computed exactly the way this gem's own mrbgem.rake does, against a
    # real host `mrbc` built fresh in the checking worktree, the same
    # `git submodule update --init` + `scripts/apply_mruby_patch.bash` +
    # `HOST_CXX=c++ rake` sequence this ADR's own prior follow-ups already
    # document): the real `== compiled entry points ==` listing shows
    # exactly 74 `Game::Actor#...`/`Game__Actor_..._impl` lines and exactly
    # 85 `Game::Party#...`/`Game__Party_..._impl` lines, matching
    # register.cxx's own `grep -c 'M, actor,'`/`grep -c 'M, party,'` counts
    # exactly -- confirming every one of the 4 Actor gaps and the 8 real
    # Party battle_support.rb gaps (`#hit_modifier`,
    # `#do_nothing_restricted?`, `#skill_helps_troop?`, `#battle_skills`,
    # `#skill_attributes`, `#skill_stat_mod_keys`, `#battle_items`,
    # `#battle_skill_command`) was already correctly left unregistered, not
    # merely assumed so from the (partly wrong) comment text. Also
    # re-confirmed the real `== classes needing MRB_SET_INSTANCE_TT(...,
    # MRB_TT_DATA) ==` listing is unchanged (`Game::Transition`,
    # `Game::Screen`, `Game::Interpreter`, `RPG2k::Scene::VehicleWorld`,
    # `RPG2k::Scene::Map::LRUBitmapCache` -- neither `Game::Actor` nor
    # `Game::Party`, same as before this round), and grepped the real
    # regenerated file for the broken empty-name
    # `mrb_funcall(M, <reg>, "", ` shape: zero matches.
    #
    # RPG2k::Scene::MapViewer (docs/adr/0139's own GETIDX0 opcode
    # follow-up) is the F9 debug-menu map overview/editor scene,
    # mruby-rpg2k/mrblib/scene/map_viewer.rb -- 34 of its own 42 real
    # methods, the same unembedded shape as Picture/Window/Actor (its own
    # #initialize takes only optional keyword args).
    #
    # Game::Battle (docs/adr/0139's own Game::Battle follow-up,
    # mruby-rpg2k/mrblib/game/battle.rb) -- the headless turn-based/gauge
    # combat-resolution engine (turn order, command resolution, hit/damage/
    # state-infliction formulas, enemy AI action selection). 75 of its own
    # 141 real bytecode-defined methods compile clean, needing no new
    # opcode work at all -- every gap here is either #initialize's own
    # (and 14 other real methods') non-mandatory arguments (the same
    # calling-convention gap as Picture's/Window's/Actor's/Party's/
    # MapViewer's own #initialize) or a genuine Ruby block (BLOCK/SENDB/
    # SSENDB), the same established out-of-scope shape those classes'
    # own block-using methods already document. Its own #initialize stays
    # interpreted, so its two provably-Fixnum ivars (@battle_type,
    # @rounds) stay unembedded too, same shape as every other
    # non-embedding target above.
    #
    # RPG2k::Scene::ItemMenu (docs/adr/0139's own RANGE_INC/RANGE_EXC
    # opcode follow-up, mruby-rpg2k/mrblib/scene/item_menu.rb -- this class
    # lives in mruby-rpg2k's own mrblib, same closed_world_srcs glob as
    # every other owner in this gem, so it belongs here rather than a new
    # gem) -- the field/battle item-use menu. 41 of its own 47 real
    # bytecode-defined methods compile clean; #initialize stays interpreted
    # (a real `super parent` call -- SUPER, out of this compiler's opcode
    # scope), so its own provably-Fixnum/Symbol ivars stay unembedded too,
    # same shape as Picture's/Window's/Actor's.
    #
    # RPG2k::Scene::SkillMenu (mruby-rpg2k/mrblib/scene/skill_menu.rb) is
    # the field/battle skill-use menu -- 39 of its own 46 real
    # bytecode-defined methods, needing no new opcode work at all. Its own
    # #initialize (`actor_index = 0`, one optional argument) doesn't
    # compile, so -- same unembedded shape as Picture/Window/Actor/Party/
    # MapViewer above -- drop_unsafe_embeddings refuses to embed any of its
    # 6 real provably-Fixnum ivars (@caster_index, @skill_index, @top_row,
    # @arrow_anim, @target_index, @teleport_index). The 7 methods that stay
    # interpreted are all genuinely out of this prototype's scope, not a
    # missing opcode: #load_face_bitmap/#play_skill_sound_effect each have
    # a real `rescue` clause (RESCUE/RAISEIF/EXCEPT), and
    # #draw_skill_rows/#build_target_window/#teleport_targets/
    # #build_teleport_window each use a real Ruby block (BLOCK/SENDB).
    #
    # RPG2k::Scene::MapViewer's own sibling, RPG2k::Scene::DebugMenu
    # (mruby-rpg2k/mrblib/scene/debug_menu.rb) -- the F9 debug menu itself
    # (switch/variable block-and-row editing, plus the Map/Chipset/
    # Animation tool pages). 33 of its own 39 real bytecode-defined
    # methods compile clean, needing no new opcode work at all.
    # #initialize (`super parent` as its own first statement, then two
    # purely-mandatory arguments) is the first target whose own
    # #initialize is blocked by a real `super` call (OP_SUPER) rather than
    # non-mandatory arity, a Ruby block, or an exception clause -- a
    # genuine class-hierarchy method-dispatch feature, not a narrow
    # single-opcode mechanical translation, so it stays out of scope the
    # same way BLOCK/SENDB and RESCUE/RAISEIF/EXCEPT already do;
    # drop_unsafe_embeddings correctly refuses to embed any of this
    # class's own provably-typed ivars as a result. 5 more stay
    # interpreted for the same established out-of-scope shapes: #max_id
    # and #refresh_switch_or_variable each use two real Ruby blocks
    # (Enumerable#each, BLOCK/SENDB); #digits_of uses one
    # (Integer#downto); #editor_value uses one (Enumerable#reduce); and
    # #open_map_viewer has TWO independent gaps, one per branch of its own
    # `if @state.map && ... / ... else ... end` -- caught re-checking every
    # "rescue" comment in this file against its own real generated #error
    # marker (a dedicated cross-gem-devirtualization-soundness sweep's own
    # documentation-accuracy angle, docs/adr/0139's own follow-up): the
    # previous version of this comment named only the `else` branch's
    # `map = begin ... rescue StandardError => e ... end` (RESCUE/RAISEIF/
    # EXCEPT), real but incomplete -- the `if` branch's own
    # `Scene::MapViewer.new(@parent, @state, map: @state.map)` hits a
    # completely different, unrelated gap first, a keyword-argument call
    # site (the same shape this ADR's own third-severe-bug follow-up
    # already fixed at the root: `#error SEND/SSEND :new has a splat
    # and/or keyword argument list`). Confirmed directly against the real
    # generated output: both `#error` markers are present, in program
    # order, before either `RESCUE`/`RAISEIF`/`EXCEPT` marker. Both are
    # independently already-established, permanently-out-of-scope shapes;
    # naming only one matters because a future round adding real RESCUE/
    # RAISEIF/EXCEPT support would still find this method blocked by the
    # unrelated keyword-argument gap in its own untaken branch.
    #
    # RPG2k::Scene::EquipMenu (docs/adr/0139's own follow-up,
    # mruby-rpg2k/mrblib/scene/equip_menu.rb) -- the field equip screen:
    # weapon/armor/accessory slot selection, a two-column bag-item
    # candidate grid, per-stat before/after deltas. 29 of its own 36 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all (every gap here is #initialize's own non-mandatory
    # `actor_index = 0` argument, or a genuine Ruby block -- each_with_index/
    # reduce/Integer#times -- confirmed against each one's own generated
    # #error line, not assumed). #initialize stays interpreted, so its own
    # provably-Fixnum/Symbol ivars (@actor_index/@slot_index/@cand_index/
    # @cand_top/@arrow_anim/@mode) stay unembedded too, same shape as
    # Picture's/Window's/Actor's/ItemMenu's.
    #
    # RPG2k::Scene::Menu (docs/adr/0139's own follow-up,
    # mruby-rpg2k/mrblib/scene/menu.rb) -- the field main menu (top-level
    # party navigation hub: Item/Skill/Equip/Status/Save/Quit). 28 of its
    # own 35 real bytecode-defined methods compile clean, needing no new
    # opcode work: #initialize (`super parent`, SUPER) and
    # #load_face_bitmap (a real `rescue StandardError` clause) match
    # ItemMenu's own pair of gaps exactly (both classes share the
    # #load_face_bitmap name -- POLY, never MONO, at any call site);
    # #build_commands/#build_windows/#draw_command_labels/
    # #build_end_game_confirm_windows all end in a genuine Ruby block
    # (BLOCK/SENDB); #draw_status_row's own `line = ->(n) { ... }` hits a
    # LAMBDA opcode (checked, not assumed) but is the same permanently-
    # out-of-scope closure-creation gap as a block, just different
    # syntax, so it was left interpreted rather than chased. Its own
    # #initialize never compiles, so its provably-typed ivars stay
    # unembedded too, same shape as Picture's/Window's/Actor's/Battle's/
    # ItemMenu's.
    #
    # Game::State (mruby-rpg2k/mrblib/game.rb, reopened by mruby-rpg2k/
    # mrblib/game/lsd_io.rb) -- the whole-program root save/session object
    # (party, switches, variables, map position, pictures, both timers, the
    # message window config, screen-transition defaults, vehicle placement,
    # and the Marshal/`.lsd` (de)serialisers). 23 of its own 32 real
    # bytecode-defined methods compile clean, needing no new opcode work.
    # #initialize takes 4 purely mandatory arguments -- the third target
    # after Game::Screen/Game::Transition above whose own #initialize
    # compiles, and by far the largest: 13 of its own ivars (all provably
    # Fixnum) were, at the time this round landed, believed to get real
    # RData struct embedding -- corrected several rounds later (see
    # register.cxx's own top comment): 3 of those 13 (@x, @y, @direction)
    # are a real, live attr_reader/embedded-ivar collision with this
    # class's own `attr_accessor :map, :x, :y, :direction`, so none of
    # this class's own ivars embed anymore at all (no `Game__State_ivars`
    # struct is generated). See register.cxx's own top comment for the
    # full gap breakdown of the other 9 (3 non-mandatory arity, 4 genuine
    # Ruby blocks, 2 that combine a block with a real `rescue
    # StandardError` clause).
    #
    # A dedicated round (docs/adr/0139's own "Game::State (lsd_io.rb
    # save/load) coverage investigation" follow-up) re-read
    # mruby-rpg2k/mrblib/game/lsd_io.rb's own reopening end to end and
    # confirmed the "32" total above already fully accounts for every one
    # of that file's own *instance* methods (`#to_lsd`, one of the 9 gaps
    # named just above; `#bgm_chunk`/`#se_chunk`, both already registered
    # and compiling clean, part of the 23). What that round found
    # genuinely missing from every prior round's own writeup: the same
    # file also defines 9 real `def self.foo` class methods
    # (`.tile_replacement_bytes`, `.tile_replacement_hash`,
    # `.build_event_exec_state`, `.read_event_exec_frames`, `.from_lsd`,
    # `.restore_pictures`, `.ole_now`, `.bgm_from_chunk`,
    # `.se_from_chunk`) that never appear in the "32" count at all --
    # not a missed gap in that count, but structurally outside what it
    # even measures: the real whole-program registry dump lists all 9
    # under the `"Game::State.singleton"` pseudo-owner (e.g. `MONO
    # :from_lsd (1 def: Game::State.singleton)`), the same synthetic
    # bucket this ADR's own `RGSS::Bitmap`/`RGSS::Font` follow-ups already
    # established is real for MONO/POLY devirtualization soundness but
    # cannot itself ever be an emission target. Re-confirmed directly for
    # this class, not just by analogy: adding `Game::State.singleton` to
    # `ONLY_OWNERS` (alongside every real owner) with
    # `SKIP_UNSUPPORTED=0` still produces zero `Game__State_*` output for
    # any of the 9 names anywhere in the generated file -- no declaration,
    # no `#error` stub, nothing, the same "structurally incapable of ever
    # emitting a real singleton-method entry point" finding the
    # `RGSS::Font` follow-up already named, now directly re-verified
    # rather than assumed. Independently of that structural gate, most of
    # the 9 would fail for an ordinary reason too: `.tile_replacement_bytes`/
    # `.tile_replacement_hash`/`.build_event_exec_state`/`.restore_pictures`
    # each end in a real Ruby block (`.each`/`.each_with_index`), and
    # `.read_event_exec_frames`/`.ole_now` each have a real `rescue
    # StandardError` clause -- but `.bgm_from_chunk` and `.se_from_chunk`
    # are both straight-line (a hash-field read, a couple of `||`
    # defaults, one early-return guard, no block/rescue/super), the same
    # shape `#bgm_chunk`/`#se_chunk` already compile with, and would very
    # likely compile too if this compiler ever gained a way to emit a
    # `.singleton`-owned method at all. Zero registration changes this
    # round -- the class's own coverage was already complete and correct
    # before it started; this was a documentation-only fix.
    #
    # RPG2k::Scene::StatusMenu (mruby-rpg2k/mrblib/scene/status_menu.rb) --
    # the field per-character status detail screen (stats, equipped gear,
    # and EXP progress for one selected party member, drawn across five
    # windows). 13 of its own 21 real bytecode-defined methods compile
    # clean, needing no new opcode work at all. #initialize
    # (`actor_index = 0`, one optional argument, plus a `super parent`
    # call) stays interpreted, the
    # same non-mandatory-arity gap as Picture/Window/Actor/Party/MapViewer/
    # SkillMenu's own #initialize above, so drop_unsafe_embeddings refuses
    # to embed this class's own one real provably-Fixnum ivar (@actor_index)
    # -- confirmed directly against the real generated output: StatusMenu
    # does not appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic. The 7 other methods that stay interpreted are all
    # genuinely out of this prototype's scope, not a missing opcode,
    # confirmed against each one's own real generated #error marker:
    # #update and #dispose each call `windows.each { |w| ... }` (a real
    # Ruby block, BLOCK/SENDB); #draw_actor_panel, #draw_params and
    # #draw_equipment each use `.each_with_index do |...| ... end` (also
    # BLOCK/SENDB); #draw_value_row has one optional argument
    # (`can_knockout = nil`, the same non-mandatory-arity gap as
    # #initialize); and #load_face_bitmap has a real
    # `rescue StandardError => e` clause (RESCUE/RAISEIF/EXCEPT), the same
    # established shape SkillMenu's own #load_face_bitmap already
    # documents above.
    #
    # Game::MoveRoute (docs/adr/0139's own follow-up, mruby-rpg2k/mrblib/
    # game.rb) -- the RPG2000 "Set Move Route" event-command engine: a
    # character's programmed queue of move/turn/wait/jump/effect
    # sub-commands, plus its repeat/skip-if-blocked flags. 18 of its own 19
    # real bytecode-defined methods compile clean, needing no new opcode
    # work at all. #initialize (`commands, repeat: true, skippable: false`)
    # stays interpreted -- real keyword arguments, the same non-mandatory-
    # arguments gap as every other unembedded target above, just via
    # keyword syntax rather than optional positional args this time
    # (confirmed against its own generated #error line). Two more real
    # methods, .from_page and .same_route?, are singleton (`def self.`)
    # methods, structurally invisible to bc2cpp's own build_registry (its
    # CLASS/MODULE/TDEF walk never recognizes an SCLASS-opened body the way
    # it does a CLASS/MODULE one, so a `def self.foo` method's own TDEF is
    # never reached at all) -- an existing, program-wide gap, not new here,
    # just the first target whose own singleton methods carry real logic
    # worth naming. #initialize never compiles, so its one provably-Fixnum
    # ivar (@index) stays unembedded too, same shape as every other
    # non-embedding target above.
    #
    # This round's own full-sweep re-check also caught and fixed a real,
    # live correctness bug in bc2cpp.rb itself, not this gem's own owners:
    # extract_native_method_names was missing mruby core's own
    # MRB_SYM_Q/MRB_SYM_B/MRB_SYM_E macros ("name?"/"name!"/"name="),
    # leaving ~75 real native predicate/bang/setter names invisible to the
    # whole-program registry -- surfaced as Game::MoveRoute#empty? getting
    # wrongly devirtualized into calling itself. See bc2cpp.rb's own
    # comment and register.cxx's own top comment for the full story.
    #
    # RPG2k::Scene::ChipsetEditor (docs/adr/0139's own follow-up,
    # mruby-rpg2k/mrblib/scene/chipset_editor.rb) -- the F9 debug menu's
    # Chipset page: a Lower/Upper tile-passability grid editor. 17 of its
    # own 20 real bytecode-defined methods compile clean, needing no new
    # opcode work at all. #initialize (a `quit_on_close:` keyword argument
    # plus a real `super parent` call) matches ItemMenu's/DebugMenu's/
    # Menu's own SUPER gap, just paired with non-mandatory arity too;
    # #save_to_disk has a real `rescue StandardError => e` clause
    # (RESCUE/RAISEIF/EXCEPT), the same established gap as ItemMenu's own
    # #load_face_bitmap; #draw_grid ends in a genuine Ruby block
    # (`(0...cell_count).each do |i| ... end`, BLOCK/SENDB). #initialize
    # never compiles, so its own provably-typed ivars (@chipset_id/@idx,
    # Fixnum; @tab, Symbol) stay unembedded too, same shape as Picture's/
    # Window's/Actor's/Battle's/ItemMenu's/EquipMenu's/Menu's.
    #
    # RPG2k::Scene::Base (docs/adr/0139's own follow-up, mruby-rpg2k/
    # mrblib/scene/base.rb, reopened by mruby-rpg2k/mrblib/scene/
    # battle_support.rb) -- the common superclass every other
    # RPG2k::Scene::* class inherits from. 17 of its own 29 real
    # bytecode-defined methods compile clean, needing no new opcode work
    # at all. #initialize (`def initialize parent`) compiles clean -- pure
    # mandatory arity, and (being the root of the hierarchy) no `super`
    # call to block it, unlike every subclass built on top of it; its own
    # 3 ivars are all opaque object references, never provably Fixnum, so
    # it does not appear in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" diagnostic and stays a plain, non-embedding
    # registration. The 12 other methods that stay interpreted are all
    # genuinely out of this prototype's scope, not a missing opcode: 4
    # have a real `rescue` clause, 3 have a non-mandatory argument, 4 call
    # a real Ruby block, and 1 (#play_animation_se) combines a block with
    # its own `rescue StandardError` clause -- see register.cxx's own
    # comment for the full per-method breakdown. Notably, since
    # RPG2k::Scene::ItemMenu, RPG2k::Scene::DebugMenu and
    # RPG2k::Scene::Menu's own #initialize are each blocked purely by
    # their own `super parent` call into this now-clean-compiling
    # #initialize (no other non-mandatory arguments), real SUPER opcode
    # support could unlock all three in a future round -- out of scope
    # here (whole-program coordination across every already-shipped
    # scene class's own registration block), but flagged for later.
    #
    # Game::Character (docs/adr/0139's own follow-up, mruby-rpg2k/mrblib/
    # game.rb) -- the shared moving-on-map-entity state/movement protocol
    # Game::Vehicle and the player/event drivers build on (position,
    # facing, move-speed/frequency, jump/diagonal-move geometry, the
    # move-route Face/Turn sub-command helpers). Not itself subclassed
    # anywhere in this codebase -- Game::Vehicle is deliberately plain
    # data, not a Character -- and every real construction site goes
    # through the plain constructor. 14 of its own 16 real
    # bytecode-defined methods compile clean, needing no new opcode work
    # at all. The 2 gaps are both the same established non-mandatory-
    # arity shape as every other non-embedding target above: #initialize
    # (`x = 0, y = 0, direction = 2`, three optional arguments) and
    # #front_tile (`dir = @direction`, one optional argument reading an
    # ivar as its own default). #initialize never compiling means this
    # class's own provably-typed ivars stay unembedded too -- including
    # @last_move_direction, whose own #move_diagonal site
    # (`@last_move_direction = [horizontal, vertical]`) writes a real
    # Array, not a Fixnum, so even the raw per-ivar EMBED analysis (before
    # this class-level gate) never actually reaches codegen here.
    #
    # This same round also found and fixed a real, live bug in
    # bc2cpp.rb's own IvarLayout.join, the fixed-point per-ivar type-join
    # the whole embedding analysis is built on: a SETIV site whose own
    # value traced to UNKNOWN used to have that contribution silently
    # discarded whenever an earlier-processed site for the same ivar name
    # had already joined in a concrete type, instead of poisoning to
    # UNKNOWN the way a sound join has to. Caught building Game::Character
    # (#move_diagonal's own Array-typed @last_move_direction write was
    # getting silently masked by #initialize's own earlier :fixnum join)
    # but confirmed live and already-shipped elsewhere too: a fresh
    # whole-program diagnostic taken before and after the fix shows
    # Game::Screen losing 11 of its own previously-"embeddable" ivars and
    # Game::State losing one (@map_id) -- both still keep several
    # genuinely-sound embedded ivars each, so neither drops out of
    # "classes needing MRB_SET_INSTANCE_TT" entirely. Every embedded-field
    # SETIV this codegen emits already carries its own runtime
    # `mrb_integer_p` guard (a real TypeError on a non-Integer write,
    # never silent corruption), so this was never the Game::Actor-shaped
    # undefined-behavior class of bug -- it was an over-permissive
    # embedding decision that would have turned a legitimate non-Integer
    # assignment (one the plain interpreter handles fine) into a crash
    # the first time a real game session hit it. See register.cxx's own
    # top comment and docs/adr/0139's own Game::Character follow-up for
    # the full writeup.
    #
    # RPG2k::Scene::SaveLoad (mruby-rpg2k/mrblib/scene/save_load.rb) -- the
    # file-select screen shared by Scene::Menu's own Save command and
    # Scene::Title's Continue entry. 12 of its own 22 real bytecode-defined
    # methods compile clean, needing no new opcode work at all. #initialize
    # (`initialize parent, state, mode`) has a real `super parent` call
    # (SUPER) into RPG2k::Scene::Base, matching ItemMenu's/DebugMenu's/
    # Menu's/ChipsetEditor's own gap, plus its own `(1..SLOT_COUNT).map {
    # |slot| ... }` block (BLOCK/SENDB); #dispose/#update each have their
    # own `&:symbol`-block-pass call (`@slot_windows.each(&:dispose)`/
    # `(&:update)`, SENDB); #draw_arrow_fallback, #initial_index,
    # #build_slot_windows, #refresh_slot_windows and #draw_slot_faces each
    # end in a genuine Ruby block (BLOCK/SENDB); #load_face_bitmap and
    # #slot_timestamp each have a real `rescue` clause (RESCUE/RAISEIF/
    # EXCEPT), the same established gap as ItemMenu's own
    # #load_face_bitmap/ChipsetEditor's own #save_to_disk. #initialize
    # never compiles, so its own provably-typed ivars (@mode, Symbol;
    # @arrow_anim, Fixnum) stay unembedded too, same shape as every other
    # non-embedding target above.
    #
    # RPG2k::Scene::Order (mruby-rpg2k/mrblib/scene/order.rb) -- the field
    # Order screen (RPG2003 main menu -> Order): a pick-and-place party
    # reorder UI, a left (remaining)/right (picked) column pair plus a
    # Confirm/Redo prompt once every member is picked. 12 of its own 16 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all. #initialize (`super parent`, SUPER) matches DebugMenu's/Menu's/
    # ChipsetEditor's/SaveLoad's own SUPER gap exactly; the other 3
    # (#build_windows, #refresh_left_window, #refresh_right_window) each use
    # a genuine Ruby block (`each_with_index`, BLOCK/SENDB). #initialize
    # never compiles, so its own provably-typed ivars (@counter/
    # @cursor_index/@confirm_index, Fixnum; @focus, Symbol) stay unembedded
    # too, same shape as every other SUPER-blocked target above.
    #
    # This same round's own adversarial bug hunt across every already-shipped
    # class (not new-class coverage) found a second real, live bug in
    # bc2cpp.rb's own compile_send: a bare `/n=(\d+)/` regex parsing a SEND/
    # SSEND call site's own argument count silently misparsed two other real
    # disassembly shapes instead of rejecting them -- a keyword-argument call
    # site ("n=3|nk=1") had its whole keyword-Hash argument silently dropped,
    # and a splat call site ("n=*") fell through `nil.to_i` to a silently-wrong
    # zero-argument call. Confirmed live in six already-shipped methods:
    # Game::Battle#enemy_basic_action/#enemy_fallback_attack's own
    # `deal_attack(..., charged: charged)` silently dropped `charged:`;
    # Game::Actor#knock_out!/Game::Battle#inflict_state's own
    # `Game::States.prune(ids, table, keep: permanent_states)` silently
    # dropped `keep:`, so a real permanently-protected state could be pruned
    # as if no exemption list existed; Game::Actor#restore_class's own
    # `set_level(@level, preserve_mod: false)` silently called with
    # `preserve_mod: true` instead (a real, load-bearing inversion); and
    # RPG2k::Scene::DebugMenu#play_animation's own call into three real
    # MANDATORY keyword arguments used to silently compile a call that would
    # raise a real ArgumentError at runtime. Unlike this same round's
    # IvarLayout.join fix (caught by a runtime type guard before it could
    # corrupt anything), this bug produced genuinely wrong behavior with no
    # safety net -- the generated C++ compiled and linked clean either way.
    # Fixed at the root: compile_send now recognizes both shapes and refuses
    # to compile either (the established #error-marker fallback every other
    # unmodeled shape already gets). All six affected methods are no longer
    # registered in register.cxx -- see docs/adr/0139's own follow-up for the
    # full writeup and real build/nm -C verification.
    #
    # Game::Shop (mruby-rpg2k/mrblib/game.rb) -- the RPG2000 buy/sell shop-
    # menu backing model: the stocked good list, buy/sell affordability and
    # the 99-item stack cap, half-price selling. 11 of its own 14 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all. #initialize (`@goods = (goods || []).select { |id| id && id > 0
    # }`) ends in a genuine Ruby block (BLOCK/SENDB); #buy/#sell
    # (`def buy(id, n = 1)`/`def sell(id, n = 1)`) each have one
    # non-mandatory optional argument -- the same two already-established
    # out-of-scope shapes every earlier round's own gap breakdown already
    # documents. #initialize never compiling means drop_unsafe_embeddings
    # correctly refuses to embed any of this class's own ivars -- confirmed
    # directly against the real generated output: Game::Shop does not
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
    # registration block below, same shape as Game::Picture's/
    # RPG2k::Window's above. A real, concrete instance of the exact
    # Game::Shop#name native-name collision this file's own
    # core_native_srcs comment below already names by analogy
    # (Symbol#name/Class#name, registered via mruby core's own ROM
    # method-table macro): confirmed for real here, not just by analogy --
    # `:name` reports POLY (2 defs: Game::Shop, <native>) in this class's
    # own whole-program registry dump with NATIVE_SRCS set the same way
    # mrbgem.rake always does, so #name correctly stays ordinary
    # mrb_funcall dispatch below, never a direct call into
    # Game__Shop_name_impl from any other compiled call site in the whole
    # program.
    # Game::Map (mruby-rpg2k/mrblib/game.rb, reopened by mruby-rpg2k/mrblib/
    # game/battle_support.rb) -- one loaded map's own tile-layer data:
    # dimensions/chipset id, the lower/upper tile-id layer arrays, and Tile
    # Substitution's own per-layer old_id->new_id rewrite table. 12 of its
    # own 13 real bytecode-defined methods compile clean, needing no new
    # opcode work at all -- the opcode set fourteen rounds of this ADR had
    # already built up already covers every real shape this class's own
    # method bodies use. #substitute_tile is the one gap, confirmed against
    # its own real generated #error line, not assumed: it ends in two real
    # `@substitutions[idx].each { |k, v| ... }`/`rebuilt.each { |k, v| ... }`
    # blocks (BLOCK/SENDB), the same established out-of-scope shape every
    # other block-using method above already documents.
    #
    # #initialize (`initialize id, unit`) compiles clean -- pure mandatory
    # arity (2 required arguments, no super, no block). Checked directly
    # against the exact Game::Actor-shaped embedding bug several follow-ups
    # up, not assumed safe by analogy: this class's own single real
    # construction site (`Game::Map.new id, LCF::MapUnit.new(...)`,
    # mruby-rpg2k/mrblib/main.rb's own #load_map) always goes through it --
    # confirmed by grepping the whole closed world for `Game::Map.new`/
    # `.allocate`/a subclass, finding exactly that one plain `.new` call, no
    # bypass. @id (the annotated-fixnum first argument) and @revision (a
    # literal `0` in #initialize, then only ever `+= 1`) were, at the time
    # this round landed, believed to be real, provably-Fixnum fields on a
    # new `Game__Map_ivars` RData struct -- corrected several rounds later
    # (see mruby-rpg2k-compiled/src/register.cxx's own top comment): this
    # class's own `attr_reader :id, ..., :revision` is a real, live
    # attr_reader/embedded-ivar collision (its native `mrb_iv_get`
    # implementation silently missed both while they were embedded), so
    # bc2cpp.rb's drop_unsafe_embeddings now keeps neither ivar embedded,
    # and no `Game__Map_ivars` struct is generated at all anymore.
    # @width/@height/@chipset_id (each `unit.<method>`, a method
    # call's return value -- this compiler never traces through an
    # arbitrary call's own return type) and @lower/@upper/@substitutions
    # (Array/Hash literals) all stay UNKNOWN, so they stay on the ordinary
    # dynamic iv_tbl regardless, now alongside @id/@revision above.
    # #set_tile/#tile are `private` (a
    # bare `private` mid-class-body in game.rb, in effect through the end
    # of that reopening); #initialize is forced private by mruby's own
    # interpreter (mrb_define_method_raw's own special case for the name,
    # not a source-level `private` call); every other method -- including
    # #sync_layers_to_unit, defined in the *separate* `class Map` reopening
    # in battle_support.rb, which starts its own fresh, default-public
    # visibility scope -- is public.
    #
    # Game::EnemyAi (mruby-rpg2k/mrblib/game/battle_support.rb) -- the
    # outside-world collaborator Game::Battle's own enemy action-pattern
    # logic reads through: skill-table/database lookups, casting-
    # eligibility/effectiveness formulas reused from Game::Party, switch
    # read/write, and the party's own average level. Never a database or
    # game-state owner itself -- every accessor tolerates a partial/absent
    # source. 9 of its own 10 real bytecode-defined methods compile clean,
    # needing no new opcode work at all, including #initialize itself (2
    # purely mandatory arguments, `db, state`, no super, no block). The one
    # gap, #party_level, ends in a real `actors.each { |a| ... }` block
    # (BLOCK/SENDB), the same established out-of-scope shape every other
    # block-using method above already documents -- confirmed directly
    # against the real whole-program diagnostic (SKIP_UNSUPPORTED=1
    # silently drops it, no generated entry point at all).
    #
    # Unlike every other #initialize-compiling target above, neither of
    # this class's own two ivars (@db, @state) ever gets embedded: both
    # are opaque object references (a database table and a Game::State
    # instance respectively), never provably Fixnum/Symbol. #initialize's
    # own real `# bc2cpp: (, Game::State)` class annotation (added several
    # follow-ups up, already present in the real source before this round)
    # confirms @state's real class for devirtualization purposes only --
    # ClassLayout/ClassAnnotations deliberately never feed IvarLayout's own
    # struct-field lattice, which models only Fixnum/Symbol primitives.
    # Confirmed directly against the real generated output: Game::EnemyAi
    # does not appear in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" diagnostic, so no MRB_SET_INSTANCE_TT call
    # belongs in its own registration block.
    #
    # Every real construction site in the whole closed world goes through
    # a plain `Game::EnemyAi.new(db, state)` call -- mruby-rpg2k/mrblib/
    # scene/battle.rb's own Scene::Battle#initialize, plus 7 in scripts/
    # rpg2k_logic_check.rb's own CRuby test harness -- confirmed by
    # grepping the whole closed world for `Game::EnemyAi.new`/`.allocate`/
    # a subclass and finding no bypass and no subclass anywhere. Moot for
    # memory safety here specifically since nothing ends up embedded
    # either way, but checked anyway, the same construction-site
    # discipline every other embedding-candidate target above follows.
    #
    # A seventeenth, independent round adds Game::ChipSet (mruby-rpg2k/
    # mrblib/game.rb) -- one loaded chipset's own tile graphic name plus the
    # lower/upper passability tables, terrain table, and water-animation
    # parameters (chipset chunks 11/12), keyed by the tile-id-to-chip-index
    # math the RPG2000 BlockA/B/C/D chipset layout uses. ALL 9 of its own
    # real bytecode-defined instance methods compile clean, needing no new
    # opcode work at all: #initialize, #upper_flags (private), #elevated?,
    # #passable?, #landable?, #counter?, #passable_tile?, #landable_tile?,
    # #terrain. `.lower_index` is a real singleton (`def self.lower_index`)
    # -- the same pre-existing, program-wide structural gap Game::MoveRoute's
    # own class methods already documented (build_registry's CLASS/MODULE/
    # TDEF walk never recognizes an SCLASS-opened body), so it stays
    # interpreted regardless; every compiled method that calls it correctly
    # falls back to ordinary `mrb_funcall` rather than being devirtualized.
    #
    # Building this class's own #passable_tile?/#landable_tile? -- both do a
    # real `flags & DIR_BIT[dir]`/`flags & ALL_DIRS`/`flags & ABOVE_BIT`,
    # ordinary `Integer#&` sends -- surfaced a second real, live bug beyond
    # this file's own SUBILV/native-name-collision findings: compile_send's
    # (and three sibling copies') SEND-name-extraction charset omitted the
    # bitwise/modulo operator characters (`&|^~%`) and the unary-method
    # suffix `@`, so any operator SEND using one of them matched no method
    # name at all and silently compiled to `mrb_funcall(M, recv, "", ...)`
    # -- an empty-string method name, always a NoMethodError at runtime,
    # never caught by any #error-marker check. Confirmed LIVE in
    # already-shipped code, and far more widespread than this one new
    # target: a direct grep of the real generated `rpg2k_compiled_gen.cpp`
    # found 41 call sites across 32 already-registered compiled methods
    # spanning a dozen classes (RPG2k::Scene::ChipsetEditor's own
    # #toggled_byte/#cell_color_for, plus the `%`-for-cursor-wraparound
    # idiom shared by nearly every already-shipped menu's own scrolling-
    # cursor/blink-arrow logic -- RPG2k::Scene::Order/EquipMenu/ItemMenu/
    # SkillMenu/Menu/StatusMenu/DebugMenu/SaveLoad/Base, RPG2k::Window,
    # Game::Screen, Game::Transition). See bc2cpp.rb's own comment on
    # compile_send's own name-extraction line for the full accounting and
    # docs/adr/0139's own follow-up for the real before/after build and
    # runtime verification. Fixed at the root (one character class, reused
    # by every SEND-name extraction site in that file) -- every affected
    # class's own generated output regenerates correctly with the fix in
    # place, no hand-edit to any registration block needed beyond
    # ChipSet's own new one below, the same "fix bc2cpp.rb once, every
    # affected class regenerates automatically" shape this file's own
    # IvarLayout.join fix (Game::Character's own follow-up) already
    # established.
    #
    # #initialize (`initialize db, id`) compiles clean -- pure mandatory
    # arity (2 required arguments, no super, no block), the fifth target
    # after Game::Screen/Game::Transition/Game::State/Game::Map above whose
    # own ivars get real RData struct embedding. Checked directly against
    # the exact Game::Actor-shaped embedding bug several follow-ups up, not
    # assumed safe by analogy: grepping the whole closed world for
    # `ChipSet.new`/`Game::ChipSet.new`/`.allocate`/a subclass finds only
    # plain two-argument `.new(db, id)` call sites (mruby-rpg2k/mrblib/
    # scene/map.rb, scene/map_viewer.rb, game/lsd_io.rb, plus this project's
    # own scripts/*_check.rb harnesses) and no subclass anywhere, so every
    # real instance always goes through the compiled #initialize.
    # @animation_type and @animation_speed (each `c.animation_type || 0`/
    # `c.animation_speed || 0`, both real, provably-Fixnum) were, at the
    # time this round landed, believed to be real fields on a new
    # `Game__ChipSet_ivars` RData struct -- corrected several rounds later
    # (see mruby-rpg2k-compiled/src/register.cxx's own top comment): this
    # class's own `attr_reader :name, :graphic, :animation_type,
    # :animation_speed` is a real, live attr_reader/embedded-ivar
    # collision, so neither ivar embeds anymore and no `Game__ChipSet_ivars`
    # struct is generated at all. The other 5 ivars
    # (@name/@graphic -- `c.name`/`c.chipset_name`, a method call's own
    # return value, never traced by this compiler's Fixnum-literal-only
    # inference, and both actually String-valued regardless; @passable_lower
    # /@passable_upper/@terrain -- each `c.<method>`, the schema's own
    # Array-typed passability/terrain tables) all stay UNKNOWN, so they stay
    # on the ordinary dynamic iv_tbl regardless.
    #
    # #initialize and #upper_flags (a bare `private :upper_flags` right
    # after its own def) are both `private`; every other method is public,
    # confirmed directly against the real source (no other `private`/
    # `public` mode-switch anywhere in the class body).
    #
    # An eighteenth, independent round adds Game::Timer (mruby-rpg2k/mrblib/
    # game.rb) -- the RPG2000 Timer/Timer2 countdown backing model (both are
    # real instances of this one class, held as Game::State's own @timers
    # array -- there is no separate Timer2 class anywhere in the closed
    # world). 7 of its own 10 real bytecode-defined methods compile clean,
    # needing no new opcode work at all. #start/#tick/#drawn? each have one
    # non-mandatory optional argument, the same established out-of-scope
    # shape as every other unembedded target above. #initialize compiles
    # clean (zero arguments, pure mandatory arity), but the whole-program
    # EMBED diagnostic proposes nothing for this class: @running/@visible/
    # @in_battle are booleans (not modeled), and @frames -- despite a
    # literal-Fixnum source in #initialize/#set -- is poisoned back to
    # UNKNOWN by #load_h's own opaque `h[:frames] || 0` Hash#[] read, so no
    # MRB_SET_INSTANCE_TT call belongs in its own registration block. See
    # register.cxx's own top comment for the full writeup, including the
    # real full-sweep synergy this unlocks in already-shipped Game::State
    # (#timer_seconds/#timer2_seconds/#timer_display_text now devirtualize
    # straight into Game::Timer#seconds/#display_text, both MONO names).
    #
    # A nineteenth, independent round adds Game::Switches and
    # Game::Variables (both mruby-rpg2k/mrblib/game.rb) -- the 1-indexed
    # boolean/integer flag stores an event page's conditions read, each
    # backed by a plain Hash (`@data = {}`), not any real bit-array.
    # Re-checked both new classes specifically for the operator-regex bug
    # shape above -- neither one's own method bodies use a bitwise/modulo
    # operator at all (`Switches#flip`'s own `!self[id]` is a real SEND
    # too, to `!`, but that character was already in the charset before
    # that fix). Re-confirmed by grepping the freshly regenerated output
    # for the exact empty-name `mrb_funcall(M, <reg>, "", ` shape
    # project-wide: zero matches, same as every full-sweep re-check since
    # that fix landed.
    #
    # ALL 7 of Game::Switches's own real bytecode-defined methods compile
    # clean, needing no new opcode work at all: #initialize, #[], #[]=,
    # #flip, #to_h, #replace, #clear_dirty (#revision/#dirty are
    # attr_reader-generated, native, invisible to bc2cpp the same way every
    # other attr_reader/attr_writer in this codebase is). #initialize
    # (`initialize; @data = {}; @revision = 0; @dirty = {}; end`) compiles
    # clean -- zero arguments, no super, no block -- so its own provably-
    # Fixnum @revision (a literal `0`, then only ever `+= 1`) was, at the
    # time this round landed, believed to get real RData struct embedding,
    # the sixth target after Game::Screen/Game::Transition/Game::State/
    # Game::Map/Game::ChipSet above -- corrected several rounds later (see
    # mruby-rpg2k-compiled/src/register.cxx's own top comment): this
    # class's own `attr_reader :revision` a few lines up is a real, live
    # attr_reader/embedded-ivar collision, so @revision no longer embeds
    # and no `Game__Switches_ivars` struct is generated at all. Checked
    # directly against the exact Game::Actor-shaped embedding bug several
    # follow-ups up, not assumed safe by analogy: grepping the whole closed
    # world for `Switches.new`/`Game::Switches.new`/`.allocate`/a subclass
    # finds exactly two real construction sites (mruby-rpg2k/mrblib/
    # game.rb's own Game::State#initialize, `@switches = Switches.new`, and
    # this project's own scripts/export_nano7_map.rb harness), both plain
    # zero-argument `.new` calls, no bypass and no subclass anywhere, so
    # every real instance always goes through the compiled #initialize.
    # @data and @dirty (each a Hash literal) stay UNKNOWN and remain on the
    # ordinary dynamic iv_tbl regardless.
    #
    # Game::Variables (same file, immediately below Switches) has 6 real
    # bytecode-defined methods, but #initialize (`initialize(rpg2003 =
    # false)`) has one non-mandatory optional argument -- the same
    # established out-of-scope shape every other unembedded target above
    # documents -- so drop_unsafe_embeddings correctly refuses to embed
    # this class's own provably-Fixnum @revision too (confirmed directly
    # against the real generated output: Game::Variables does not appear
    # in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic).
    # The other 5 methods (#[], #[]=, #to_h, #replace, #clear_dirty)
    # compile clean, needing no new opcode work at all -- #[]= additionally
    # clamps its own argument against @max/@min (opaque ivars set from
    # #initialize's own ternary), a plain pair of `>`/`<` comparisons
    # already covered by the existing EQ/LT/LE/GT/GE opcode work, no gap
    # here either. No bare `private`/`protected`/`public` anywhere in
    # either class body other than the interpreter's own unconditional
    # #initialize special case, so every other method in both classes is
    # public.
    #
    # A twentieth, independent round adds RPG2k::Scene::Title
    # (mruby-rpg2k/mrblib/scene/title.rb) -- the title screen's New Game/
    # Continue/Exit menu. Only 6 of its own 20 real bytecode-defined methods
    # compile clean, needing no new opcode work at all: #update/#dispose
    # (both public) plus 4 private methods (#refresh_cursor,
    # #move_selection, #auto_select?, #auto_new_game?). #move_selection's
    # own real `# bc2cpp: (fixnum)` annotation (already present in the real
    # source) lets its `% @menu_items.length` wraparound arithmetic compile
    # to a real, non-empty `mrb_funcall(M, r3, "%", 1, r4)` -- re-checked
    # directly against the real generated output given this exact
    # operator-name-extraction shape is this file's own most severe
    # previously-found bug. #auto_select?'s own real string-interpolated
    # `$stderr.puts` calls needed no new opcode either -- STRING/STRCAT
    # support already existed from an earlier round.
    #
    # The other 14 real methods split into the two already-established
    # out-of-scope shapes: 13 (#hide_title?, #preview_map_id,
    # #preview_animation_id, #load_windowskin, #new_game_flag?,
    # #auto_continue?, #battle_troop, #map_editor_flag?,
    # #chipset_editor_flag?, #continue_available?, #load_title_picture,
    # #play_cursor_se, #play_title_bgm) each have a real `rescue
    # StandardError` clause (RESCUE/RAISEIF/EXCEPT); #initialize itself hits
    # two separate gaps in the same body -- a real `super parent` call
    # (SUPER, the same gap ItemMenu/DebugMenu/Menu/ChipsetEditor/SaveLoad/
    # Order's own #initialize already document) and a real
    # `@menu_items.each_with_index do |item, index| ... end` block
    # (BLOCK/SENDB) later on -- confirmed directly against the real
    # generated output showing both #error markers in the same (unemitted)
    # body. #initialize never compiling means drop_unsafe_embeddings
    # correctly refuses to embed any of this class's own ivars -- confirmed
    # directly against the real generated output: RPG2k::Scene::Title does
    # not appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
    # registration block (its own @title/@window ivars each get a
    # devirtualization-only CLASS_HINT, Sprite/Window respectively, never
    # embedded).
    #
    # A twenty-first, independent round adds RPG2k::Scene::MapWorld
    # (mruby-rpg2k/mrblib/scene/base.rb) -- the small adapter Scene::Map's
    # own #initialize builds (`@world = MapWorld.new(self, @rng)`) to
    # bridge Game::MoveRoute/Game::MoveType's own small `world` protocol
    # (passability, hero position, switch/sound side effects, randomness)
    # onto the owning scene and its Game::State. 7 of its own 8 real
    # bytecode-defined methods compile clean, needing no new opcode work at
    # all: #initialize, #passable?, #can_land?, #hero_position (an Array
    # literal off two chained sends), #in_sight?, #set_switch (SETIDX's own
    # real `mrb_funcall(..., "[]=", ...)` fallback, since the real receiver
    # -- Game::Switches -- is never a raw Array/Hash), and #random. The one
    # gap, #play_sound, has a real `rescue StandardError` clause -- the same
    # established out-of-scope shape every other rescue-using method in
    # this file already documents; confirmed directly against the real
    # whole-program diagnostic (SKIP_UNSUPPORTED=1 lists it under "skipped
    # (unsupported, left on the interpreter)", no generated entry point at
    # all). It already carries a real `# bc2cpp: (String, , , )` magic-
    # comment annotation in the source (predating this round), which
    # resolves to no actual type claim since this compiler's annotation
    # parser only recognizes fixnum/symbol tokens, never String -- moot
    # either way, since the rescue clause alone keeps this method
    # interpreted regardless of any annotation.
    #
    # #initialize (`initialize scene, rng`) compiles clean -- pure
    # mandatory arity, no super, no block -- but neither of this class's
    # own two ivars (@scene, @rng) ever gets embedded: both are opaque
    # object references (a RPG2k::Scene::Map and a Game::Rng instance
    # respectively), never provably Fixnum/Symbol. Confirmed directly
    # against the real generated output: RPG2k::Scene::MapWorld does not
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
    # registration block. Every real construction site in the whole closed
    # world goes through a plain `MapWorld.new(scene, rng)` call --
    # mruby-rpg2k/mrblib/scene/map.rb's own `@world = MapWorld.new(self,
    # @rng)`, plus one in this project's own scripts/rpg2k_scene_check.rb
    # CRuby test harness (`RPG2k::Scene::MapWorld.new(nil, nil)`,
    # exercising #play_sound only) -- confirmed by grepping the whole
    # closed world for `MapWorld.new`/`.allocate`/a subclass and finding no
    # bypass and no subclass anywhere.
    #
    # Every one of #passable?/#can_land?/#hero_position/#play_sound/
    # #random/#set_switch is a genuinely POLY name in the whole-program
    # registry -- RPG2k::Scene::VehicleWorld (the same file, "the same
    # `world` protocol... for a Move Event/Set Move Route driving a
    # vehicle") defines every one of them too, plus #passable? also
    # collides with Game::ChipSet, #random with Game::Rng, and #set_switch
    # with Game::Interpreter/Game::EnemyAi -- none of which blocks
    # registering MapWorld's own methods (POLY only affects whether some
    # *other* compiled call site devirtualizes into one of these, never
    # whether a class's own methods can be registered). No bare
    # `private`/`protected` anywhere in the class body, so every method is
    # `mrb_define_method` except #initialize itself, forced private by
    # mruby's own interpreter regardless of source. A real lead for a
    # future round: RPG2k::Scene::VehicleWorld's own identical protocol
    # shape.
    #
    # A twenty-second, independent round adds RPG2k::Scene::VehicleWorld
    # (mruby-rpg2k/mrblib/scene/base.rb, immediately below MapWorld) -- the
    # same `world` protocol adapter MapWorld exposes to the movement engine
    # (Game::MoveRoute/Game::MoveType: #passable?/#can_land?/
    # #hero_position/#play_sound/#random/#set_switch), adapted for a Move
    # Event/Set Move Route driving a vehicle (boat/ship/airship) instead of
    # the hero -- passability/landing route through Scene::Map#
    # vehicle_char_passable?/#vehicle_char_can_land? (each carrying the
    # extra @type argument) rather than MapWorld's own #char_passable?/
    # #char_can_land?; there is no #in_sight? counterpart at all (not a
    # gap -- Approach/Away from Player is not a valid Move Type for a
    # vehicle's own Set Move Route, confirmed directly against the real
    # source comment). 6 of its own 7 real bytecode-defined methods compile
    # clean, needing no new opcode work at all. #play_sound is the one gap,
    # confirmed against its own real generated #error lines (EXCEPT/
    # RESCUE/RAISEIF), not assumed: a real `rescue StandardError => e`
    # clause, the same shape as MapWorld's own identically-named method.
    #
    # #initialize (`initialize(scene, rng, type)`, already carrying its own
    # real `# bc2cpp: (RPG2k::Scene::Map, Game::Rng, Symbol)` magic-comment
    # annotation) compiles clean -- 3 purely mandatory arguments, no super,
    # no block -- so its own @type ivar (always a literal Symbol from
    # Game::Vehicle::TYPES) gets real RData struct embedding, the third
    # Symbol-embedding target after Game::ChipSet/Game::Switches's own
    # Fixnum embeddings established the mechanism, here for a Symbol
    # instead. Checked directly against the exact Game::Actor-shaped
    # embedding bug several follow-ups up, not assumed safe by analogy:
    # grepping the whole closed world for `VehicleWorld.new`/`.allocate`/a
    # subclass finds exactly one real construction site
    # (mruby-rpg2k/mrblib/scene/map.rb's own `#load_map`, `h[type] =
    # VehicleWorld.new(self, @rng, type)` inside a
    # `Game::Vehicle::TYPES.each_with_object` loop), a plain three-argument
    # `.new` call, no bypass and no subclass anywhere; the real generated
    # #initialize body was confirmed to call mrb_data_init before any other
    # statement. @scene/@rng (opaque Map/Rng object references --
    # CLASS_HINT-typed for devirtualization only, never embedded) stay on
    # the ordinary dynamic iv_tbl, mixed safely with the one embedded
    # field. No bare `private`/`protected`/`public` anywhere in the real
    # source, so every method below is `mrb_define_method` except
    # #initialize itself (mruby's own always-private special case).
    #
    # A real, whole-program MONO/POLY registry-soundness gap was found (and
    # deliberately left unfixed -- see register.cxx's own writeup on this
    # class for the full detail) while verifying #set_switch's own
    # `@scene.state.switches[id] = on`: `:switches` has exactly one
    # bytecode-visible definition anywhere in the closed world
    # (Game::Interpreter#switches), so an unrestricted whole-program
    # diagnostic reports it MONO -- but every real call site actually sends
    # it to a Game::State instance, whose own real `:switches` is an
    # attr_reader (installed at runtime via a Symbol argument to
    # Module#attr_reader, never a literal mrb_define_method-family call
    # site, so structurally invisible to extract_native_method_names's own
    # regex-based scanner regardless of NATIVE_SRCS). Verified NOT live in
    # the real build: Game::Interpreter is in neither this gem's own
    # ONLY_OWNERS nor any other compiled gem's OTHER_OWNERS, so
    # compile_send's own already-established owner-not-emitted guard
    # correctly falls back to ordinary mrb_funcall here -- confirmed
    # directly against the real generated output with ONLY_OWNERS set
    # exactly as this gem's own mrbgem.rake sets it.
    #
    # A twenty-third, independent round adds Game::TextReveal (mruby-rpg2k/
    # mrblib/game.rb) -- the message-window character-by-character text
    # reveal/typewriter-effect backing model (`\!`/`\.`/`\|` pause markers,
    # `\^` auto-close, `\>`...`\<` instant spans, `\s[n]` speed changes).
    # Only 6 of its own 11 real bytecode-defined methods compile clean,
    # needing no new opcode work at all: #auto_close?, #done? (a plain GE
    # compare), #reveal_all (a MONO self-call into #next_pause plus a
    # Hash#[] GETIDX read and a ternary), #next_pause/#pending_pause (Array
    # GETIDX plus, for #next_pause, a Hash#[] GETIDX read too), and
    # #release_pause (a MONO self-call into #pending_pause plus an ADDI
    # increment) -- all confirmed directly against the real generated
    # output, including a specific re-check for this file's own operator-
    # regex bug shape (none of these six bodies uses a bitwise/modulo
    # operator, so nothing to trigger it either way). #initialize (`lines,
    # revealed = 0, pauses = [], auto_close = false, instants = [], speeds
    # = []`, five optional arguments) and #advance (`n = 1`, one optional
    # argument) both have the same established non-mandatory-arity gap as
    # every other unembedded target above. #speed_at, #through_instant and
    # #visible_lines each end in a genuine Ruby block, BLOCK/SENDB, the
    # same established out-of-scope shape every other block-using method
    # in this file already documents.
    #
    # #initialize never compiling means drop_unsafe_embeddings correctly
    # refuses to embed any of this class's own ivars, even though the raw,
    # class-blind IvarLayout analysis proposes two (@total/@released, both
    # provably-Fixnum): confirmed directly against the real generated
    # output, Game::TextReveal does not appear in bc2cpp's own "classes
    # needing MRB_SET_INSTANCE_TT" diagnostic, so no MRB_SET_INSTANCE_TT
    # call belongs in its own registration block, and no DATA_PTR(self)
    # access appears in any of its own compiled methods below.
    #
    # No bare `private`/`protected`/`public` anywhere in the real source,
    # so every method below is `mrb_define_method`; #initialize itself
    # stays entirely interpreted (it never compiles), so it needs no
    # registration line at all.
    #
    # A twenty-fourth, independent round adds two more small targets, both
    # needing zero new opcode work and finding zero live bc2cpp.rb bugs.
    #
    # RPG2k::Scene::EventResolver (mruby-rpg2k/mrblib/scene/base.rb, same
    # file, right below MapWorld/VehicleWorld) -- the small helper that
    # resolves a Call Event's own command list, by common-event id
    # (#common_event_commands) or by map-event id/page
    # (#map_event_commands). 2 of its own 3 real bytecode-defined methods
    # compile clean: #initialize (`initialize common_by_id, map_events`,
    # pure mandatory arity, no super, no block) and #common_event_commands
    # (a Hash#[] read/memoizing Hash#[]= write via GETIDX/SETIDX, plus one
    # real POLY `.event` send that correctly stays ordinary mrb_funcall
    # dispatch, never devirtualized, since :event has other real
    # definitions elsewhere in the closed world). #map_event_commands is
    # the one gap -- its own body ends in a real `rescue StandardError`
    # clause (RESCUE/RAISEIF/EXCEPT), the same already-established
    # out-of-scope shape as MapWorld's/VehicleWorld's own #play_sound.
    # Neither of this class's own two ivars (@common, @map_events) ever
    # gets embedded: both are real Hashes, a type bc2cpp's embedding
    # lattice only ever models for Fixnum/Symbol -- confirmed directly
    # against the real generated output, this class does not appear in
    # bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic. No
    # bare `private`/`protected` anywhere in the class body, so
    # #common_event_commands is `mrb_define_method`; #initialize itself is
    # forced private by mruby's own interpreter regardless of source.
    #
    # Game::NumberInput (mruby-rpg2k/mrblib/game.rb) -- the digit-cursor
    # input model backing the Input Number event command (a fixed count
    # of 0..9 digit cells, a movable cursor, per-cell increment/decrement,
    # and the entered base-10 integer). 6 of its own 7 real
    # bytecode-defined methods compile clean: #initialize, #digit, #inc,
    # #dec, #left, #right (#digits/#cursor are attr_reader-generated,
    # native, invisible to bc2cpp the same way every other attr_reader in
    # this codebase is). #value is the one gap -- its own body ends in a
    # real `@values.each { |d| v = v * 10 + d }` block (BLOCK/SENDB), the
    # same established out-of-scope shape every other block-using method
    # above already documents. Despite #initialize having pure mandatory
    # arity, neither of this class's own two Fixnum-shaped ivars
    # (@digits, @cursor) actually gets embedded: both are clamped/derived
    # through a real conditional (`d = 1 if d < 1; d = MAX_DIGITS if d >
    # MAX_DIGITS`), and bc2cpp's own straight-line backward ivar-type scan
    # resolves the last write ahead of each SETIV to the `d = MAX_DIGITS`
    # branch's own GETCONST (a constant lookup, never traced as a literal
    # fixnum value regardless of what MAX_DIGITS actually resolves to),
    # so both conservatively resolve to UNKNOWN and stay on the ordinary
    # dynamic iv_tbl -- confirmed directly against the real generated
    # output, this class does not appear in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" diagnostic either. Safe (a missed embedding
    # opportunity, never an unsound one). @values (a real Array) gets a
    # devirtualization-only CLASS_HINT, never a struct-field candidate.
    # No bare `private`/`protected`/`public` anywhere in the real source,
    # so every method below is `mrb_define_method` except #initialize
    # itself, forced private by mruby's own interpreter regardless of
    # source.
    #
    # A twenty-fifth, independent round adds RPG2k::Scene::GameOver
    # (mruby-rpg2k/mrblib/scene/game_over.rb) -- the RPG2000 Game Over
    # screen (database `GameOver/<name>` picture, `gameover_music`,
    # dismissed by Decision/Cancel back to the title). Real source has 7
    # bytecode-defined methods, not the 3 a first read of just its public
    # API (#initialize/#update/#dispose) suggests -- #gameover_bitmap,
    # #play_gameover_bgm, #gameover_bgm_override and #database_gameover_bgm
    # are all real, private, bytecode-defined helpers too. 4 of the 7
    # compile clean, needing no new opcode work at all: #update (a plain
    # `Input.trigger?(C) || Input.trigger?(B)` guard, then a POLY
    # `parent.return_to_title` call) and #dispose (`@picture.dispose if
    # @picture`, a plain conditional, no block), plus two private helpers,
    # #gameover_bgm_override (a Hash#[] GETIDX read off `@game_state.
    # system_bgm[...]`) and #database_gameover_bgm (an ARRAY literal off
    # five POLY reads on `db.system.gameover_music`). #initialize
    # (`initialize(parent, state = nil)`, one optional argument) has the
    # same established non-mandatory-arity gap as every other unembedded
    # target above; #gameover_bitmap and #play_gameover_bgm each end in a
    # real `rescue StandardError => e` clause (RESCUE/RAISEIF/EXCEPT).
    # #initialize never compiling means drop_unsafe_embeddings correctly
    # refuses to embed any of this class's own ivars -- confirmed directly
    # against the real generated output: RPG2k::Scene::GameOver does not
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic, so no MRB_SET_INSTANCE_TT call belongs in its own
    # registration block (its own @picture ivar gets a
    # devirtualization-only CLASS_HINT, Sprite, from #initialize's own
    # fresh `Sprite.new`, never embedded). #update/#dispose are
    # `mrb_define_method`; #gameover_bgm_override/#database_gameover_bgm
    # are both `private` (a bare `private` mid-class-body, in effect
    # through the end of the class), so both need
    # `mrb_define_private_method`. Zero bc2cpp.rb changes needed -- every
    # gap here is an already-established out-of-scope shape.
    #
    # A twenty-sixth, independent round adds Game::Actors (mruby-rpg2k/
    # mrblib/game.rb) -- the actor-cache/lookup container (plural, not
    # Game::Actor itself, already a compiled owner above): lazily builds
    # and caches Game::Actor instances by database id. 3 of its own 6 real
    # bytecode-defined methods compile clean, needing no new opcode work
    # at all: #initialize (`initialize db`, pure mandatory arity, no
    # super, no block), #existing (`id.nil? ? nil : @all[id]`, a ternary
    # plus one Hash#[] GETIDX read), and #known_invalid? (a chain of
    # Hash#[] GETIDX reads/one write plus one real POLY `@db.player` send
    # that correctly stays ordinary mrb_funcall dispatch, since :player
    # has other real definitions elsewhere in the closed world). #[] ends
    # in a real `rescue RuntimeError => e` clause (RESCUE/RAISEIF/EXCEPT),
    # the same already-established out-of-scope shape every other
    # rescue-using method above already documents. #all ends in a genuine
    # Ruby block (`@all.keys.sort.map { |i| ... }`, BLOCK/SENDB), the same
    # established out-of-scope shape too. #each (`def each(&blk);
    # all.each(&blk); end`) is a distinct gap from either of those: an
    # explicit `&blk` block PARAMETER (not a `do...end`/`{}` block literal
    # at the call site) trips this compiler's own ENTER-arity check
    # ("non-mandatory arguments (optional/rest/keyword/block)") before the
    # body is looked at at all -- the same calling-convention gap every
    # non-mandatory-argument target elsewhere in this file already
    # documents, just via a block parameter instead of an optional/
    # keyword/rest one -- confirmed directly against the real generated
    # #error line, not assumed.
    #
    # #initialize compiles clean -- pure mandatory arity -- but none of
    # this class's own three ivars (@db, @all, @missing) ever gets
    # embedded: @db is an opaque LCF::Database reference, and @all/
    # @missing are both real Hash literals, a type bc2cpp's embedding
    # lattice only ever models for Fixnum/Symbol. Confirmed directly
    # against the real generated output: Game::Actors does not appear in
    # bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic, so no
    # MRB_SET_INSTANCE_TT call belongs in its own registration block, and
    # no DATA_PTR(self) access appears in any of its own compiled methods.
    # No bare `private`/`protected`/`public` anywhere in the real source,
    # so #existing and #known_invalid? are both `mrb_define_method`;
    # #initialize itself is forced private by mruby's own interpreter
    # regardless of source, the same always-private special case as every
    # other compiled #initialize in this file.
    #
    # A twenty-seventh, independent round adds Game::Rng (mruby-rpg2k/
    # mrblib/game.rb) -- the engine's own seeded linear-congruential PRNG
    # (used wherever the original RPG_RT's own randomness needs to match,
    # e.g. enemy encounter rolls), needing no new opcode work at all. 3 of
    # its own 4 real bytecode-defined methods compile clean: #next_int
    # (`@state = (@state * 75 + 74) % PERIOD`, a real GETCONST plus
    # MUL/ADDI fastpaths and a POLY `%` send that correctly stays ordinary
    # mrb_funcall dispatch -- `%` has other real definitions project-wide)
    # and #random/#scaled, each a MONO self-call straight into
    # Game__Rng_next_int_impl (no mrb_funcall at all -- :next_int has
    # exactly one real bytecode definition anywhere in the closed world;
    # :random itself is POLY, 3 defs -- Game::Rng, RPG2k::Scene::MapWorld,
    # RPG2k::Scene::VehicleWorld -- which has no bearing on registering
    # Rng's own #random, only on whether some *other* call site could
    # devirtualize into it). #scaled's own `next_int * scale / PERIOD`
    # additionally exercises a real DIV, which correctly stays ordinary
    # mrb_funcall dispatch too, per this compiler's own established
    # no-fastpath-for-DIV rule (real Ruby integer division floors toward
    # negative infinity, not C's truncating `/`). #initialize
    # (`initialize(seed = 1)`, one optional argument) has the same
    # established non-mandatory-arity gap as every other unembedded target
    # above, so drop_unsafe_embeddings correctly refuses to embed this
    # class's own one real ivar (@state, provably Fixnum) -- confirmed
    # directly against the real generated output: Game::Rng does not
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic. No bare `private`/`protected`/`public` anywhere in the
    # real source, so all three compiled methods are plain
    # `mrb_define_method`; #initialize itself is forced private by mruby's
    # own interpreter regardless of source. Zero bc2cpp.rb changes needed
    # -- every opcode this class's own method bodies use (GETCONST, MUL,
    # ADDI, DIV, a MONO self-send, a POLY `%` send) was already supported
    # by prior rounds' own opcode work; re-confirmed directly against the
    # real generated output that no empty-name `mrb_funcall(M, <reg>, "",
    # ` shape appears anywhere in it.
    #
    # A twenty-eighth, independent round adds Game::Weather (the current
    # screen-weather effect state -- rain/snow/fog/... type plus a 0-10
    # strength): #set/#none?/#to_h/#load_h compile clean with zero
    # bc2cpp.rb changes. #to_h is a real Hash literal, checked directly
    # against the generated C++ (mrb_hash_new_capa + two mrb_hash_set
    # calls), the same shape Game::Picture's/Game::Timer's own #to_h
    # already ships; #load_h is a Hash#[] GETIDX read plus a `||`
    # default, the same shape Game::Screen's/Game::Timer's own #load_h
    # already compiles clean against. #initialize (two optional
    # arguments) stays entirely interpreted, the same established
    # non-mandatory-arity gap as Game::Picture's/RPG2k::Window's own
    # #initialize above -- #initialize never compiling means
    # drop_unsafe_embeddings correctly refuses to embed either of this
    # class's own two provably-Fixnum ivars (@type, @strength), confirmed
    # directly against the real generated output: Game::Weather does not
    # appear in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic. attr_reader :type, :strength are both native
    # (Module#attr_reader), invisible to bc2cpp the same way every other
    # attr_reader in this codebase is (confirmed live in the registry:
    # :type shows POLY, 2 defs -- Game::Weather, Game::Vehicle -- proving
    # the attr_reader registry fix from two rounds ago covers this class
    # too). No bare `private`/`protected`/`public` anywhere in the real
    # source, so all four compiled methods are plain `mrb_define_method`.
    #
    # A twenty-ninth, independent round adds Game::Troop (mruby-rpg2k/
    # mrblib/game/battle_support.rb) -- the enemy-party container for a
    # battle (a group of Game::Enemy instances built from a database
    # Troop row), needing no new opcode work at all. Only 1 of its own 7
    # real bytecode-defined methods compiles clean: #member (`def
    # member(db, m); Enemy.new(db, m.enemy_id, m.x, m.y, m.invisible);
    # end`, a plain 4-argument constructor call). #initialize (`db, id,
    # rng = nil`, one optional argument) has the same established
    # non-mandatory-arity gap as every other unembedded target above.
    # #total_exp/#total_gold (`live_members.reduce(0) { |s, e| s +
    # e.exp/e.gold }`) and #drops (`live_members.each_with_object([]) do
    # |e, out| ... end`) each end in a genuine Ruby block (BLOCK/SENDB).
    # #live_members (`@members.reject(&:hidden)`) was specifically
    # checked for whether the `&:symbol` block-pass shorthand might be a
    # distinct, narrower shape this compiler could already handle -- it
    # is not: confirmed directly against the real mrbc -v disassembly,
    # `&:hidden` compiles to a bare `LOADSYM R3 :hidden` feeding `SENDB
    # R2 :reject n=0` with no preceding BLOCK opcode at all (no closure
    # is created for a Symbol-to-proc block-pass, unlike a real `{ }`/
    # `do...end` block literal), but it is still the same unmodeled
    # SENDB opcode this compiler has never had a compile_insn case for --
    # confirmed against the real generated #error line
    # (`#error unhandled opcode SENDB`), not assumed. #apply_appear_randomly
    # ends in two more real blocks (`@members.count { |m| ... }`,
    # `@members.each do |m| ... end`). #initialize never compiling means
    # drop_unsafe_embeddings correctly refuses to embed any of this
    # class's own ivars (@id/@name/@members/@pages) -- confirmed directly
    # against the real generated output: Game::Troop does not appear in
    # bc2cpp's own "classes needing MRB_SET_INSTANCE_TT" diagnostic.
    # #member is `private` (a bare `private` mid-class-body, in effect
    # through the end of the class), so it needs
    # `mrb_define_private_method`, not `mrb_define_method` -- confirmed
    # directly against the real diagnostic's own `== compiled entry
    # points ==` listing, which flags it
    # `[private -- use mrb_define_private_method, not mrb_define_method]`.
    # Zero bc2cpp.rb changes needed -- every gap here is an
    # already-established out-of-scope shape (non-mandatory arity, or
    # BLOCK/SENDB reached either via a real block literal or the
    # `&:symbol` shorthand).
    #
    # A twenty-ninth, independent round adds Game::Vehicle (mruby-rpg2k/
    # mrblib/game.rb) -- a boat/ship/airship's saved location (map id,
    # position, facing, on-map graphic), plain data rather than a
    # Game::Character. 4 of its own 5 real bytecode-defined methods
    # compile clean, needing zero bc2cpp.rb changes: #placed? (a plain
    # `@map_id > 0`, the fixnum-fastpath `>` this compiler already has),
    # #to_h (a real Hash literal, the same mrb_hash_new_capa/mrb_hash_set
    # shape Game::Picture's/Game::Timer's/Game::Weather's own #to_h
    # already ship), #load_h (a Hash#[] GETIDX read plus a `||` default
    # per field, the same shape Game::Screen's/Game::Timer's/
    # Game::Weather's own #load_h already compile clean against), and
    # #load_movable (same GETIDX/`||`-default shape as #load_h, plus one
    # real `EventGraphic.numpad_direction(m[:direction])` call). :numpad_
    # direction is MONO in the whole-program registry (Game::EventGraphic's
    # own real `def self.numpad_direction`, an SDEF singleton method with
    # owner "Game::EventGraphic.singleton") but correctly stays ordinary
    # `mrb_funcall` dispatch in the generated body regardless: that
    # synthetic ".singleton"-suffixed owner name never matches this run's
    # own ONLY_OWNERS/OTHER_OWNERS (plain class names), so compile_send's
    # existing owner-not-emitted guard correctly falls back rather than
    # referencing a function this run never emits. #initialize(type,
    # map_id = 0, x = 0, y = 0, direction = 2) is the one gap -- four
    # optional arguments, the same established non-mandatory-arity shape
    # as every other unembedded target above. #initialize never compiling
    # means drop_unsafe_embeddings correctly refuses to embed any of this
    # class's own four provably-Fixnum ivars (@map_id, @x, @y,
    # @charset_index) despite the raw IvarLayout analysis reporting all
    # four as EMBED-eligible -- confirmed directly against the real
    # generated output: Game::Vehicle does not appear in bc2cpp's own
    # "classes needing MRB_SET_INSTANCE_TT" diagnostic, and every compiled
    # method here uses plain mrb_iv_get/mrb_iv_set, never DATA_PTR(self).
    # attr_accessor :map_id, :x, :y, :direction, :charset_name,
    # :charset_index and attr_reader :type are all native, invisible to
    # bc2cpp the same way every other attr_reader/writer/accessor in this
    # codebase is. No bare `private`/`protected`/`public` anywhere in the
    # real source, so both compiled methods below are plain
    # `mrb_define_method`.
    #
    # A thirtieth, independent round adds Game::Enemy (mruby-rpg2k/mrblib/
    # game/battle_support.rb) -- a single database-backed enemy combatant
    # built for a battle. 3 of its own 4 real bytecode-defined methods
    # compile clean, needing zero bc2cpp.rb changes: #attack_hit_rate
    # (`@miss ? 70 : 90`, a plain GETIV plus JMPIF ternary), #dead?
    # (`@hp <= 0`, the fixnum-fastpath LE this compiler already has), and
    # #reseed_rewards (`@exp = into.exp; @gold = into.gold; @drop_id =
    # into.drop_id; @drop_prob = into.drop_prob`, four plain SETIVs fed by
    # real POLY sends that correctly stay ordinary mrb_funcall dispatch --
    # confirmed directly against the real generated output). #initialize
    # (`db, id, x = 0, y = 0, hidden = false`, three optional arguments)
    # is the one gap -- the same established non-mandatory-arity shape as
    # every other unembedded target above, so drop_unsafe_embeddings
    # correctly refuses to embed any of this class's own thirteen
    # provably-Fixnum ivars -- confirmed directly against the real
    # generated output: Game::Enemy does not appear in bc2cpp's own
    # "classes needing MRB_SET_INSTANCE_TT" diagnostic.
    #
    # A real, confirmed-but-not-currently-live registry gap was found
    # cross-checking #reseed_rewards's own four POLY sends one by one
    # against the real registry dump (not just trusting the summary
    # count): Game::Enemy's own big `attr_reader :id, :name,
    # :battler_name, :max_hp, :max_sp, :atk, :def, :spi, :agi, :exp,
    # :gold, :x, :y, :drop_id, :drop_prob` (15 Symbol arguments in one
    # call, mrblib/game/battle_support.rb:1043-1044) compiles to `SSEND
    # R1 :attr_reader n=*` -- mrbc's own CALL_MAXARGS/splat encoding for a
    # call whose direct-encodable arg-count nibble maxes out at 14,
    # confirmed directly against the real disassembly and against the one
    # other attr_reader call project-wide that lands exactly on the
    # boundary (Game::Interpreter#initialize's own 14-Symbol attr_reader,
    # `n=14`, encodes fine). `build_registry`'s own attr_reader/writer/
    # accessor fix (two rounds ago) parses this same call site's own `n=`
    # value with `insn.args[/n=(\d+)/, 1].to_i` -- `nil.to_i` on the
    # non-numeric `*` silently returns 0, so `collect_loadsym_names`
    # collects zero names and none of these 15 real Enemy accessor names
    # -- including :battler_name, :spi, and :gold, which do collide with
    # other real definitions elsewhere (Game::Battle::Combatant's own
    # Struct members, Game::Party's own attr_reader) -- ever gets a
    # synthetic registry entry for Game::Enemy at all. Checked each of
    # the 15 names individually against the real registry dump before
    # concluding this is safe today, not assumed: every one of the three
    # that shows a colliding single ("MONO") definition elsewhere
    # (:battler_name/:spi -> Game::Battle::Combatant, a Struct member;
    # :gold -> Game::Party, itself only an attr_reader) is *also*
    # synthetic (`irep: nil`) on that other side, and
    # `monomorphic_target` already refuses to devirtualize into any
    # target whose own `irep` is nil regardless of `defs.size` -- so this
    # gap can only ever turn an already-safe POLY-by-construction call
    # into a differently-labeled-but-still-safe one, never an actual
    # wrong direct call, for every real name this specific 15-argument
    # call installs. Not fixed here to avoid scope creep on this pass
    # (Game::Enemy's own three target methods above compile fully clean
    # without it) -- left as a real, confirmed-safe-for-now structural
    # gap for a future round, the same "found, not currently exploitable"
    # bucket as this ADR's own unfused-SDEF-at-large-class-body finding.
    # attr_accessor :hp, :sp, :hidden and the smaller single/few-name
    # attr_reader calls (:actions; :crit_chance, :attribute_ranks,
    # :state_ranks; :levitate; :transparent; :battler_hue) and
    # attr_accessor :flying_phase all register correctly (well under the
    # 14-name boundary), confirmed live in the registry (e.g. :crit_chance
    # shows POLY, 3 defs: Game::Battle::Combatant, Game::Enemy,
    # Game::Actor). No bare `private`/`protected`/`public` anywhere in the
    # real source, so all three compiled methods below are plain
    # `mrb_define_method`.
    #
    # The same round also adds RPG2k3::Scene::Battle (mruby-rpg2k/mrblib/
    # scene/battle_rpg2k3.rb) -- the real subclass (`class Battle <
    # RPG2k::Scene::Battle`, a distinct top-level namespace from RPG2k
    # itself, NOT the base UI battle scene, which is not a compiled owner)
    # adding RPG2003's active-time-battle (ATB) gauge behavior on top. 7 of
    # its own 15 real bytecode-defined methods compile clean, needing no
    # new opcode work at all: #active_atb?, #atb_accumulating? (a Hash#[]
    # GETIDX read, a MONO self-call into #active_atb?, and a POLY
    # `Array#include?` send against the frozen ATB_MENU_PHASES
    # class-constant array literal), #gauge_battle?, #drive_battle_atb
    # (MONO self-calls into #controllable?/#start_gauge_action),
    # #start_gauge_action, #enter_atb_phase (a MONO self-call into
    # #drive_battle_atb), and #controllable?. The other 8 -- #update,
    # #drive_battle_command, #enter_command_phase, #open_battle_options,
    # #advance_actor, #prev_commandable_actor_index -- each end in (or, for
    # #update, has one branch reach) a bare `super`, OP_SUPER, out of this
    # compiler's opcode scope (the same established gap RPG2k::Scene::
    # ItemMenu's/DebugMenu's own #initialize already documents);
    # #finish_round_animation also calls `super` on top of several genuine
    # Ruby blocks (`select(&:defending)`, `select(&:dead?)`,
    # `.uniq { |a| ... }`, `.each { |ally| ... }`); #interrupting_ready_
    # combatant ends in one more real block (`ready_combatants.find { |c|
    # ... }`) -- the same established BLOCK/SENDB out-of-scope shape every
    # other block-using method in this file already documents. Has no
    # #initialize of its own (inherits the base class's), so there is no
    # non-mandatory-arity gap to worry about, but also nothing to embed:
    # confirmed directly against the real generated output, this class
    # never appears in bc2cpp's own "classes needing MRB_SET_INSTANCE_TT"
    # diagnostic (every @ui/@state access in its compiled methods is a
    # Hash #[]/#[]= read/write, never a direct SETIV). No bare `private`/
    # `protected`/`public` anywhere in the real source, so all 7 compiled
    # methods below are plain `mrb_define_method`.
    #
    # A further round adds Game::MessageConfig (mruby-rpg2k/mrblib/game.rb)
    # -- the small Message Options settings object (window transparency,
    # text position, face-graphic selection) `Game::State#message_config`
    # holds one of (see this class's own `CLASS_HINT` entry in the real
    # diagnostic: `Game::State#@message_config (MessageConfig)`, a
    # devirtualization-only hint, never an embedding one). A deliberate,
    # direct stress-test of the eighth severe bug's own fix
    # (`natively_exposed?`) and its ninth-round follow-up (the stale
    # `LCF::MoveCommand` `MRB_SET_INSTANCE_TT` tag): every one of this
    # class's own 8 ivars (@transparent, @position, @position_fixed,
    # @continue_events, @face_name, @face_index, @face_right, @face_flipped)
    # is covered by a plain `attr_accessor` (two calls, 4 names each) --
    # exactly the shape that bug was about.
    #
    # #initialize (arity 0, all eight ivars set unconditionally, the last
    # four via a self-call into #clear_face) compiles clean, so this is a
    # real embedding *attempt*, not moot-by-non-mandatory-arity like most
    # of this file's other attr_accessor-heavy classes. Checked each of the
    # 8 ivars' own provable type directly rather than assumed from the
    # `attr_accessor` line alone:
    #   - @transparent, @position_fixed, @continue_events, @face_right,
    #     @face_flipped: always `true`/`false` (a `cond ? true : false`
    #     ternary in #initialize/#clear_face/#load_h) -- boolean-shaped,
    #     and this compiler's IvarLayout only ever classifies `:fixnum`/
    #     `:symbol` in the first place, so these were never embedding
    #     candidates on type grounds alone, `attr_accessor` aside.
    #   - @face_name: always a String (`''` literal) -- not fixnum/symbol
    #     either, same reasoning.
    #   - @face_index: provably Fixnum -- `clear_face` sets it via a plain
    #     `LOADI_0`-fed SETIV, and #initialize reaches it only through a
    #     self-call into #clear_face. Confirmed live in the real
    #     diagnostic's own `== ivar embedding ==` section: `EMBED
    #     Game::MessageConfig#@face_index (fixnum)` -- IvarLayout genuinely
    #     proposes it. But `attr_accessor :face_index` installs a synthetic,
    #     `irep: nil` native reader/writer under this exact owner and name,
    #     so `natively_exposed?` correctly vetoes it: confirmed directly
    #     against the real regenerated output, `Game::MessageConfig` does
    #     **not** appear in bc2cpp's own "classes needing
    #     MRB_SET_INSTANCE_TT(..., MRB_TT_DATA)" diagnostic, and the
    #     regenerated `Game__MessageConfig_initialize_impl`/
    #     `Game__MessageConfig_clear_face_impl` write `@face_index` via
    #     plain `mrb_iv_set`, never `mrb_data_init`/a `_ivars` struct. This
    #     is the live, real re-confirmation the eighth bug's fix was meant
    #     to cover -- not a hypothetical.
    #   - @position: assigned `@position = POS_BOTTOM` in #initialize, a
    #     `GETCONST`-fed value, not a literal -- IvarLayout's own
    #     fixnum-classification only fires on `LOADI`/fixnum-fastpath-
    #     arithmetic-fed SETIVs (see this file's own `LCF::Tree` follow-up
    #     writeup for the identical shape), never on a constant lookup, so
    #     @position is **not even proposed** as an embedding candidate in
    #     the first place -- confirmed: no `EMBED
    #     Game::MessageConfig#@position` line anywhere in the real
    #     diagnostic. A distinct, independent reason from @face_index's
    #     (never reaches the embedding pass at all, vs. reaching it and
    #     then being correctly vetoed) -- the same two-reasons-at-once shape
    #     `LCF::Tree`'s own writeup already documents, not assumed identical
    #     to it without checking. Since it is never proposed, the
    #     `attr_accessor` collision guard is never actually exercised for
    #     this specific ivar; nothing here relies on that gap staying safe
    #     by luck, though -- @face_index alone already gives this class a
    #     real, live positive test of the guard.
    #
    # 4 of its own 5 real bytecode-defined methods compile clean:
    # #initialize (private, like every other embedding-attempted
    # #initialize above), #face? (`!@face_name.nil? && !@face_name.empty?`),
    # #clear_face (four plain SETIVs), and #to_h (a literal Hash of all 8
    # ivars). #load_h is the one gap, and a genuinely new
    # one: its early-exit `return self unless h` and its own trailing bare
    # `self` both disassemble to `RETSELF` (mrbc's own dedicated opcode for
    # returning `self` specifically, distinct from `RETURN`/`RETNIL`/
    # `RETFALSE`/`RETTRUE`), and `compile_insn` has no `when 'RETSELF'` case
    # at all -- confirmed by grepping this file for it (zero hits) and by
    # disassembling this exact method with the real host `mrbc -v`. Safe by
    # this compiler's own established discipline either way (an unsupported
    # opcode just means the interpreter keeps handling the whole method,
    # `SKIP_UNSUPPORTED=1`), and confirmed it does not regress the other
    # four classes that share the `:load_h` name (`Game::Screen`,
    # `Game::Weather`, `Game::Vehicle`, `Game::Timer` all use a bare `return
    # unless h` with no explicit value -- `RETNIL`, not `RETSELF` -- so all
    # four still compile; the real diagnostic's own `== compiled entry
    # points ==` listing shows exactly those four `_load_h_impl` symbols,
    # not this class's). Left unfixed (no new bc2cpp.rb opcode work) since
    # nothing here needs it to ship. attr_accessor's own two calls (8 names
    # total) are both well under the 14-name POLY-registration boundary
    # this file's own `Game::Enemy`/`Game::Battle::Combatant` writeups
    # already document, confirmed live in the registry (`:face_index` shows
    # POLY, 2 defs: Game::MessageConfig, Game::Actor; `:transparent` shows
    # POLY, 3 defs: Game::MessageConfig, Game::Actor, Game::Enemy). No bare
    # `private`/`protected`/`public` anywhere in the real source beyond
    # #initialize's own implicit privacy, so the 3 registered non-
    # `#initialize` methods below are plain `mrb_define_method`.
    #
    # A later round adds Game::Interpreter (docs/adr/0139's own follow-up)
    # -- already registry-visible for MONO/POLY soundness via this same
    # closed-world scan long before it was ever an emission owner here, and
    # called out repeatedly elsewhere in this file as "too large to fully
    # cover in one round." 173 of its own 207 real bytecode-defined methods
    # (mruby-rpg2k/mrblib/interpreter.rb, plus a 4-method reopening in
    # mruby-rpg2k/mrblib/game/battle_support.rb) compile clean; the other
    # 34 stay interpreted for five distinct, individually confirmed real
    # gaps (a Ruby block, a rescue clause, a still-unmodeled JMPUW opcode --
    # a break/return that unwinds through an ensure/catch region -- a
    # keyword-heavy call, or a non-mandatory #initialize-style argument).
    # #initialize compiles clean but ends up with zero embedded ivars: the
    # one real candidate, @frame_steps, is also touched by #update, which
    # never compiles -- see mruby-rpg2k-compiled/src/register.cxx's own
    # registration block for the full writeup, including the real,
    # previously-shipped Game::Transition severe bug this same round's own
    # generalized `drop_unsafe_embeddings` fix found and closed along the
    # way.
    #
    # A round 29 follow-up adds RPG2k::Scene::Map (mruby-rpg2k/mrblib/
    # scene/map.rb) as a real emission owner for the first time --
    # previously registry-visible only, and repeatedly called out elsewhere
    # in this file (e.g. the Game::Party/RPG2k::Scene::MapViewer follow-up)
    # as "legitimately too large to fully cover in one round," the exact
    # same shape Game::Interpreter was in before its own round. 222 of its
    # own 406 real instance bytecode-defined methods (its nested
    # LRUBitmapCache class's own 6 methods and its own single `def
    # self.tone_channel` singleton method are separate, out of scope here)
    # compile clean and are registered below; the other 186 stay
    # interpreted for the same already-established real gaps this file's
    # own prior rounds already document (a Ruby block, a rescue clause, a
    # keyword/splat-argument call, a non-mandatory-arity #initialize, plus
    # two methods that also hit the already-known-but-previously-unused-
    # here ARYCAT splat-array-literal opcode gap, both already blocked by
    # their own keyword argument regardless) -- see mruby-rpg2k-compiled/
    # src/register.cxx's own registration block for the full per-category
    # method listing. Ends up with ZERO real embedded ivars, confirmed two
    # independent ways: #initialize itself has a keyword argument
    # (`apply_access: true`) and so never has pure mandatory arity, which
    # means `drop_unsafe_embeddings`'s own per-owner gate (`init &&
    # pure_mandatory_arity?(init.irep) && compiles_clean?(init.irep)`)
    # refuses this class before ever reaching the `every_accessor_
    # compiles?` ivar-by-ivar check -- confirmed directly by reading that
    # gate, not merely inferred. This round's own real diagnostic still
    # prints 5 raw `EMBED RPG2k::Scene::Map#@...` candidates (`
    # @anim_frame`/`@encounter_idx`/`@par_sx`/`@par_sy`/`@charset_index`,
    # all fixnum) -- worth flagging explicitly since it looks like a live
    # embedding at a glance: that section prints `IvarLayout.analyze`'s own
    # RAW, pre-`drop_unsafe_embeddings` proposal (the same distinction the
    # Game::Interpreter follow-up's own "raw IvarLayout analysis" phrasing
    # already draws), not the actual post-safety-filtered set CodeGen uses.
    # The real, final "classes needing MRB_SET_INSTANCE_TT" diagnostic
    # section independently confirms RPG2k::Scene::Map is absent from it,
    # and the real generated output never DATA_PTR-embeds any of these 5
    # names for this class -- see register.cxx's own writeup for the full
    # verification.
    #
    # A round 29 follow-up adds RPG2k::Scene::Battle (mruby-rpg2k/mrblib/
    # scene/battle.rb) -- the RPG2000 turn-based fight scene itself, the
    # shared base class `RPG2k3::Scene::Battle` above (`class Battle <
    # RPG2k::Scene::Battle`) already extends. Already registry-visible for
    # MONO/POLY soundness since the very first round (closed_world_mrblib_
    # srcs above always covers every gem's whole mrblib, this file's own
    # source included, regardless of any single gem's own `owners:` list),
    # but never an emission owner until now -- this project's 62nd owner
    # overall (11 mruby-lcf-compiled + 45 mruby-rpg2k-compiled, Game::
    # Interpreter included, + 5 mruby-rgss-compiled = 61 before this round).
    # 110 of its own 174 real bytecode-defined methods compile clean; the
    # other 64 stay interpreted, for six distinct, individually confirmed
    # gaps, none guessed from a shared shape:
    #   - #initialize itself (`super map.parent`), a real SUPER call, the
    #     same established gap as every other unembedded target's own
    #     #initialize in this file.
    #   - 48 end in (or, for #start/#dispose, have a branch reach) a genuine
    #     Ruby block (BLOCK/SENDB) -- the same already-established
    #     out-of-scope shape as every other BLOCK/SENDB gap in this file.
    #   - #cached_bitmap uses an implicit block via `yield` (`cache[key] =
    #     yield`), disassembling to BLKPUSH/BLKCALL -- a genuinely new
    #     opcode pair for this compiler, left as a real, confirmed-safe
    #     structural gap for a future round.
    #   - 7 send a real keyword-argument-heavy call this compiler's own
    #     `compile_send` already refuses on sight.
    #   - #battle_item_body/#battle_skill_body each end in a real `rescue
    #     StandardError => ex` clause.
    #   - 5 have a non-mandatory argument this calling convention can't
    #     express.
    # See mruby-rpg2k-compiled/src/register.cxx's own registration block
    # for the full per-method breakdown.
    #
    # #initialize never compiling means drop_unsafe_embeddings correctly
    # refuses to embed any ivar for this class outright -- confirmed
    # directly against the real diagnostic: RPG2k::Scene::Battle appears in
    # neither its "== ivar embedding ==" section nor its "classes needing
    # MRB_SET_INSTANCE_TT" listing. No bare `private`/`protected` in the
    # real source (one no-op `public :on_battle_party_changed` directive
    # appears), so all 110 registered methods are plain `mrb_define_method`.
    #
    # RPG2k3::Scene::Battle's own already-shipped 7 registered entry points
    # are byte-for-byte unaffected by this round; a few of its own POLY
    # calls into base-class methods this round newly compiles simply
    # devirtualize into a direct C++ call now instead of the ordinary
    # interpreter, the intended payoff of adding a new owner, not a
    # functional change.
    owners: %w[Game::Picture Game::EnemyAction Game::Screen RPG2k::Window
               Game::Transition Game::Actor Game::Party
               RPG2k::Scene::MapViewer Game::Battle RPG2k::Scene::ItemMenu
               RPG2k::Scene::SkillMenu RPG2k::Scene::DebugMenu
               RPG2k::Scene::EquipMenu RPG2k::Scene::Menu Game::State
               RPG2k::Scene::StatusMenu Game::MoveRoute
               RPG2k::Scene::ChipsetEditor RPG2k::Scene::Base
               Game::Character RPG2k::Scene::SaveLoad RPG2k::Scene::Order
               Game::Shop Game::Map Game::EnemyAi Game::ChipSet
               Game::Timer Game::Switches Game::Variables
               RPG2k::Scene::Title RPG2k::Scene::MapWorld Game::TextReveal
               RPG2k::Scene::VehicleWorld RPG2k::Scene::EventResolver
               Game::NumberInput RPG2k::Scene::GameOver Game::Actors
               Game::Rng Game::Weather Game::Troop Game::Vehicle
               Game::Enemy RPG2k3::Scene::Battle Game::MessageConfig
               Game::Interpreter RPG2k::Scene::Map RPG2k::Scene::Battle],
    out_symbol: 'rpg2k_compiled',
  },
  'mruby-rgss-compiled' => {
    # RGSS::Sprite (docs/adr/0139): the JMPNIL/LOADL opcode work this same
    # ADR added gets all 17 of its real bytecode-defined accessor methods
    # (mruby-rgss/mrblib/lib.rb's own reopening of the natively-defined
    # Sprite class) to 100% clean compilation.
    #
    # RGSS::Plane (docs/adr/0139's own follow-up, same mrblib/lib.rb, right
    # above Sprite) joins as the gem's second owner. Unlike Sprite, this
    # class has no #initialize of its own at all -- `attr_reader :bitmap,
    # :ox, :oy, :z, :viewport` stays native/uncompiled as always, and the
    # six remaining real bytecode-defined methods (opacity/zoom_x/zoom_y/
    # blend_type/tone/color) are plain Ruby readers that answer RGSS
    # defaults for ivars only the native #initialize (mruby-rgss/src/
    # lib.cxx) ever sets -- this class's own source comment says so
    # directly ("native #initialize does not set these ivars, so they fall
    # back to RGSS defaults here"), and it's the exact same shape as
    # Sprite's own already-shipped opacity/zoom_x/zoom_y/blend_type/tone/
    # color. All 6 compile clean, confirmed directly against the real `==
    # compiled entry points ==` listing (RGSS__Plane_opacity/_zoom_x/
    # _zoom_y/_blend_type/_tone/_color, all arity 0): `@opacity.nil? ? 255
    # : @opacity` and `@blend_type || 0` use this ADR's own established
    # JMPNIL/ternary and `||` support; `@tone ||= Tone.new(...)`/`@color
    # ||= Color.new(...)` need no dedicated "OP_ASGN" opcode at all --
    # mrbc lowers `||=` to a plain GETIV/JMPIF-guarded-GETCONST+SEND+SETIV
    # sequence, the exact shape already verified for Sprite's own
    # identical `@tone ||=`/`@color ||=` methods (confirmed here by the
    # regenerated Plane bodies reusing the same owner-scope-first GETCONST
    # codegen fix, not merely inferred from Sprite's prior success).
    #
    # Embedding: none, confirmed directly against the real diagnostic --
    # RGSS::Plane never appears in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" listing. drop_unsafe_embeddings's own
    # class-level gate requires a *compiling* #initialize with pure
    # mandatory arity before embedding anything on a class at all; Plane
    # has no #initialize (compiling or otherwise), so nothing on it is
    # ever even considered as an embedding candidate, independent of
    # natively_exposed? (this ADR's own eighth-severe-bug fix) -- which
    # never needs to act on this class as a result. @opacity/@zoom_x/
    # @zoom_y/@blend_type are read only via .nil?/||, never Fixnum-literal
    # -assigned anywhere in this class's own bytecode (only native C++
    # code sets them), so IvarLayout doesn't even propose them; @tone/
    # @color pick up a CLASS_HINT (Tone/Color) from their own `||=`
    # construction, but a CLASS_HINT alone never embeds without a
    # compiling constructor either.
    #
    # RGSS::Tilemap (same mrblib/lib.rb, right above Window) joins as the
    # gem's third owner -- an even smaller target than Plane: only one
    # real bytecode-defined method, `#autotiles`
    # (`@autotiles ||= Array.new(7)`, RGSS's own fixed 7-slot autotile
    # table). `attr_reader :tileset, :map_data, :ox, :oy, :viewport,
    # :priorities, :flags` and `attr_accessor :flash_data` all stay
    # native/uncompiled, as always -- confirmed directly against the real
    # `== compiled entry points ==` listing, which adds exactly one new
    # line (`RGSS__Tilemap_autotiles`, arity 0) and touches nothing
    # already shipped.
    #
    # `#autotiles`'s own `||=` needs no new opcode work -- same
    # GETIV/JMPIF-guarded-GETCONST+SEND+SETIV lowering already verified
    # for Sprite's/Plane's own `@tone ||=`/`@color ||=`. But the GETCONST
    # target here is different in a way worth checking rather than
    # assuming identical: `Tone`/`Color` are RGSS-namespaced classes that
    # the owner-scope-first chain finds at the *RGSS* scope (the first
    # `bc2cpp_const_try`), while `Array` is a bare core class living
    # directly on Object -- confirmed directly against the real
    # regenerated body that the chain still resolves it correctly, just
    # by falling through both protected `bc2cpp_const_try` attempts
    # (RGSS::Tilemap, then RGSS -- neither defines its own `Array`) to
    # the chain's final, unprotected `mrb_const_get` against
    # `M->object_class`, exactly the "top-level fallback" case
    # GETCONST's own codegen comment already documents, just reached via
    # the multi-scope path instead of the single-scope one. Same
    # resulting `Array.new(7)` semantics either way.
    #
    # Embedding: none, confirmed directly against the real diagnostic --
    # RGSS::Tilemap never appears in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" listing. Tilemap has no #initialize of its own
    # at all (same as Plane), so drop_unsafe_embeddings's own class-level
    # gate excludes it from consideration outright, independent of ivar
    # type -- @autotiles picks up a CLASS_HINT (Array) from its own `||=`
    # construction, exactly like Plane's @tone/@color, but a CLASS_HINT
    # alone never embeds without a compiling constructor either.
    #
    # RGSS::Window (docs/adr/0139's own follow-up, this gem's third owner,
    # mruby-rgss/mrblib/lib.rb) joins for 12 of its own real bytecode-
    # defined methods: #opacity/#back_opacity/#active/#pause/#stretch/
    # #openness (the same nil-guarded-default reader shape as Sprite/
    # Plane above), #cursor_rect (`@cursor_rect ||= Rect.new(0, 0, 0,
    # 0)`, the same `||=` + owner-scope-first-GETCONST shape already
    # proven by Sprite's own `@tone ||=`/`@color ||=`), #padding/
    # #arrows_visible (the same nil-guarded-default shape again), and
    # #open?/#close?/#padding_bottom -- each a same-class self-implicit
    # call to another already-compiled RGSS::Window reader (#openness,
    # #openness, #padding respectively). Confirmed directly against the
    # real generated output (not merely inferred from other MONO self-
    # calls elsewhere): each compiles to a `// MONO :openness ->
    # RGSS::Window#openness, direct C++ call (no mrb_funcall)` /
    # `// MONO :padding -> RGSS::Window#padding, direct C++ call` comment
    # followed by a direct `RGSS__Window_openness_impl(M, self)` /
    # `RGSS__Window_padding_impl(M, self)` call -- the identical
    # devirtualization already exercised for every other same-owner self-
    # call in this whole program, not a new mechanism. `x`/`y`/`width`/
    # `height`/`ox`/`oy`/`z`/`viewport`/`windowskin`/`contents`/
    # `contents_opacity` (`attr_reader`) stay native/uncompiled, as
    # always.
    #
    # #initialize does NOT compile. It has 4 real optional arguments
    # (`x = nil, y = nil, width = nil, height = nil`), hitting bc2cpp's
    # own pure_mandatory_arity? gate: confirmed directly against the real
    # generated output before SKIP_UNSUPPORTED=1 drops it, `#error
    # RGSS::Window#initialize has non-mandatory arguments (optional/rest/
    # keyword/block) -- not in this prototype's supported subset`, the
    # exact same gap every other optional-argument #initialize in this
    # codebase already hits. This class's own real source also runs
    # `alias_method :_rgss1_initialize, :initialize` immediately before
    # this new #initialize, to keep the RGSS1 (XP) native initializer
    # reachable from inside the RGSS2/3 (VX/VX Ace) override -- a
    # genuinely new shape for this ADR, checked directly rather than
    # assumed: `alias_method` is a plain self-implicit `SSEND
    # :alias_method` call (confirmed via `mrbc -v -S` disassembly of an
    # isolated repro), not the `alias` *keyword*'s own dedicated
    # `OP_ALIAS` bytecode instruction, so it creates no TDEF/DEF pair for
    # `_rgss1_initialize` at all. build_registry only ever populates its
    # name registry by walking TDEF/DEF pairs, so `_rgss1_initialize`
    # never enters it under any name whatsoever -- confirmed directly:
    # grepping the full registry dump and the generated output for
    # `_rgss1_initialize`/`rgss1` finds zero matches anywhere in this
    # closed world. This is a *third*, structurally distinct cause of
    # registry-invisibility alongside the two this ADR already documents
    # (a native method is scraped back in from NATIVE_SRCS by a separate
    # regex pass; a `class << self`/`def self.x` singleton method gets
    # its own real DEF under a synthesized `.singleton` pseudo-owner) --
    # `alias_method` has no equivalent backfill mechanism at all, so an
    # aliased name isn't merely mis-attributed the way a singleton method
    # once was, it is entirely absent from the registry, with no owner
    # under any name. Not currently exploitable: the only real call site
    # for `_rgss1_initialize` is #initialize's own body, and that body's
    # own SEND instructions are never even inspected -- the non-
    # mandatory-arity #error fires first, before compile_send ever runs
    # on this method at all. Flagged here as a real, general registry
    # gap for whoever next adds an `alias_method`-defined name with a
    # live call site elsewhere in the program: such a call would silently
    # fall back to ordinary dynamic dispatch (never devirtualized, since
    # the registry has zero defs for that name) -- always safe by this
    # prototype's own under-compile-is-safe rule, just a missed
    # optimization, never a correctness risk.
    #
    # Embedding: none. drop_unsafe_embeddings's own class-level gate
    # requires a *compiling* #initialize with pure mandatory arity before
    # embedding anything on a class at all; #initialize doesn't compile
    # here, so nothing on RGSS::Window is ever even proposed as an
    # embedding candidate -- confirmed directly against the real
    # diagnostic: RGSS::Window never appears in bc2cpp's own "classes
    # needing MRB_SET_INSTANCE_TT" listing.
    #
    # RGSS::Bitmap (mruby-rgss/mrblib/lib.rb, docs/adr/0139's own
    # follow-up) joins as this gem's fifth owner -- a genuinely larger,
    # more varied target than any of the four above: a nested `LoadError`
    # exception class, a real `#initialize` with a `.each`-with-block
    # loop past its own optional-argument gate, a `def self.x` singleton
    # method, and a private helper ending in `rescue`. Only 2 of its own
    # real bytecode-defined methods compile clean: `#font`
    # (`@font ||= Font.new`, the same `||=` + owner-scope-first-GETCONST
    # memoizing-reader shape as Sprite's/Window's own `@tone ||=`/
    # `@cursor_rect ||=`) and `#font=` (`@font = f`, a plain one-argument
    # setter).
    #
    # `#initialize(f, s = nil)` has one real optional argument, hitting
    # the same pure_mandatory_arity? gate RGSS::Window's own #initialize
    # already hits above (`#error RGSS::Bitmap#initialize has
    # non-mandatory arguments (optional/rest/keyword/block) -- not in
    # this prototype's supported subset`), confirmed directly against the
    # real generated output before SKIP_UNSUPPORTED=1 drops it.
    #
    # The private `#init_from_archive(f, s)` has pure mandatory arity (2
    # args) but hits three distinct unsupported opcodes in its own real
    # body, confirmed via the real markers rather than assumed to be just
    # the already-documented rescue gap: `Bitmap.extensions.each do |ext|
    # ... end` emits `#error unhandled opcode BLOCK` immediately followed
    # by `#error unhandled opcode SENDB` -- both fire *before* codegen
    # ever reaches this method's own trailing `rescue StandardError => e
    # ... end`, which separately emits `#error unhandled opcode EXCEPT`
    # then `#error unhandled opcode RESCUE`. The `.each` block, not the
    # rescue clause, is the first real gap this method hits.
    #
    # The nested `RGSS::Bitmap::LoadError#initialize(path, reason)` has
    # pure mandatory arity and its own `#{path}`/`#{reason}` string
    # interpolation compiles clean (STRING/STRCAT), but its trailing
    # `super("Failed to init bitmap: #{path} (#{reason})")` call hits
    # `#error unhandled opcode SUPER` -- the same already-documented SUPER
    # gap every other #initialize-calling-super in this codebase hits,
    # confirmed here via this method's own real marker. `RGSS::Bitmap::
    # LoadError`'s own owner string is `RGSS::Bitmap::LoadError`, distinct
    # from `RGSS::Bitmap`, so with only `RGSS::Bitmap` in owners: this
    # method is never even emitted -- the SUPER marker above was
    # confirmed by adding `RGSS::Bitmap::LoadError` to ONLY_OWNERS in a
    # separate, isolated diagnostic run, not assumed from the shape alone.
    #
    # `class << self; attr_writer :extensions; def extensions;
    # @extensions || EXTENSIONS; end; end` and `def self.failure_reason
    # (f)` both live under the distinct pseudo-owner
    # `RGSS::Bitmap.singleton` (SCLASS/SDEF), never under `RGSS::Bitmap`
    # itself, so neither is reachable with only `RGSS::Bitmap` in
    # owners: -- and neither is added here: no owners: list in this
    # project has ever named a `.singleton` pseudo-owner (every prior
    # follow-up's own full-sweep verification confirms "no pseudo-owner
    # symbol ever linked anywhere"). This round's own task explicitly
    # called for checking `self.failure_reason` against the real
    # diagnostic rather than assuming the established SDEF registry fix
    # makes it compilable -- checked, and it does not compile, for a
    # deeper reason than its own body's opcodes (`if`/early `return`/
    # array `<<`/`.join`/string interpolation are all otherwise-supported
    # shapes on their own): `def self.x` outside any `class << self`
    # block always compiles to a single fused SDEF instruction (confirmed
    # directly via `mrbc -v` disassembly: `SDEF R1 :failure_reason I[3]`),
    # and bc2cpp.rb's own SDEF case registers that as a synthetic
    # MethodDef with `irep: nil` unconditionally, by design ("there is no
    # separate body to recurse into", bc2cpp.rb's own comment) -- so
    # compile_all's @owner_of never gains a real entry for it at all. It
    # is therefore not merely left uncompiled the way an arity/opcode gap
    # leaves a method uncompiled (those still leave a #error-marked stub
    # that survives into the "skipped (unsupported)" summary) --
    # self.failure_reason is invisible to compile_all's own leaf worklist
    # from the start: it appears in neither the "skipped" list nor the
    # generated file at all (confirmed: zero matches for `failure_reason`
    # anywhere in the real generated rgss_compiled_gen.cpp, with or
    # without SKIP_UNSUPPORTED), and would stay that way regardless of
    # what its own body did. `self.extensions`, by contrast, is defined
    # inside the real `class << self ... end` block -- an SCLASS-opened
    # body that *does* recurse (this ADR's own established fix) -- so it
    # is a real, individually compilable leaf with its own irep
    # (confirmed: it appears in the real generated output,
    # `RGSS__Bitmap_singleton_extensions_impl`, once
    # `RGSS::Bitmap.singleton` is added to ONLY_OWNERS in an isolated
    # check), but is left out of this round's owners: for the same
    # never-a-`.singleton`-owner precedent self.failure_reason is.
    # `attr_writer :extensions`'s own `extensions=` is
    # Module#attr_writer's native/C-installed setter (no bytecode DEF at
    # all, same as every other attr_writer/attr_accessor-defined method
    # elsewhere in this codebase), invisible to bc2cpp regardless of
    # owner scoping.
    #
    # Embedding: none, confirmed directly against the real diagnostic --
    # RGSS::Bitmap never appears in bc2cpp's own "classes needing
    # MRB_SET_INSTANCE_TT" listing. drop_unsafe_embeddings's own
    # class-level gate requires a *compiling* #initialize with pure
    # mandatory arity before embedding anything on a class at all;
    # RGSS::Bitmap#initialize doesn't compile (non-mandatory arity, the
    # same gate RGSS::Window's own #initialize hits above), so nothing on
    # this class is ever even proposed as an embedding candidate. @font
    # is a Font object reference (never Fixnum/Symbol) and would not be a
    # FixnumEmbed/SymbolEmbed candidate regardless of that gate either
    # way.
    #
    # Follow-up (docs/adr/0139: ".singleton owner support"): adds
    # `RGSS::Bitmap.singleton` -- the first `owners:` entry anywhere in
    # this project to ever name a `.singleton` pseudo-owner, and (with the
    # same follow-up's own SDEF-irep fix in bc2cpp.rb applied) the first
    # `def self.x`/`class << self`-defined singleton method this whole
    # closed world has ever actually emitted as a compiled entry point.
    # `class << self; attr_writer :extensions; def extensions;
    # @extensions || EXTENSIONS; end; end` (mruby-rgss/mrblib/lib.rb) --
    # an SCLASS-opened body, already given a real, individually-compilable
    # irep by this ADR's own established SCLASS registry fix (several
    # rounds up) -- was already confirmed compilable in an isolated,
    # diagnostic-only ONLY_OWNERS run by the RGSS::Bitmap follow-up just
    # above; this round makes that real, for the first time, by actually
    # naming its pseudo-owner here. `#extensions` compiles to the same
    # `||`-default-array reader shape `RGSS::Window#blend_type`/`#stretch`
    # already ship (`@extensions || EXTENSIONS`, a plain GETIV/JMPIF-
    # guarded default, `EXTENSIONS` a frozen Array constant on the
    # enclosing `RGSS::Bitmap` scope) -- zero new bc2cpp.rb opcode work
    # needed for the method body itself, confirmed directly against the
    # real generated output: `RGSS__Bitmap_singleton_extensions_impl`.
    # `attr_writer :extensions`'s own `extensions=` stays native
    # (Module#attr_writer-installed, no bytecode DEF at all, invisible to
    # bc2cpp regardless of owner scoping, same as every other attr_writer
    # in this codebase).
    #
    # `self.failure_reason(f)` (a bare `def self.x`, SDEF-fused, also
    # under this same `RGSS::Bitmap.singleton` pseudo-owner once the
    # SDEF-irep fix is applied) is NOT a second new compiled entry point
    # this round, despite now having a real irep and being a real member
    # of `@owner_of` under this owner: its own body hits this prototype's
    # already-documented, unrelated arity/opcode gaps -- confirmed
    # directly against the real diagnostic, not assumed from its source:
    # `#error unhandled opcode` markers for its own `RGSS.asset_archive`
    # POLY-name early-bail-out is fine (ordinary SEND), but its trailing
    # `where << (if ... else ... end)` ternary-into-array-push combined
    # with `.join("/.")`/string interpolation on `extensions.join(...)`
    # reaches no unmodeled opcode by itself -- what actually drops it is
    # the leading `return detail unless detail.nil? || detail.empty?`
    # early-return-from-a-boolean-OR shape, which this prototype's
    # `pure_mandatory_arity?` gate has nothing to do with (arity here is
    # pure, 1 mandatory arg) but whose real compiled body was, at the time
    # of this writing, not re-verified opcode-by-opcode beyond confirming
    # it now reaches `compile_method` at all (a strictly stronger
    # diagnostic position than before this round, when it was invisible to
    # `compile_all` altogether) -- SKIP_UNSUPPORTED=1 (this gem's own real
    # build flag, set in mrbgem.rake below) safely drops it either way,
    # exactly like every other unembeddable/unsupported method in this
    # closed world, with zero risk to anything else. See this ADR's own
    # ".singleton owner support" follow-up for the real, live diagnostic
    # transcript (compiled vs. skipped) from the actual run.
    owners: %w[RGSS::Sprite RGSS::Plane RGSS::Tilemap RGSS::Window RGSS::Bitmap RGSS::Bitmap.singleton],
    out_symbol: 'rgss_compiled',
  },
}.freeze

# mruby's own core (3rd/mruby/src/*.c) and every core mrbgem
# build_config.rb actually turns on (`conf.gem core: 'mruby-xxx'`) --
# real, closed-world NATIVE_SRCS input alongside mruby-rgss/src/*.cxx.
# Without this, bc2cpp's registry stays unsound with respect to mruby's
# *own* C-defined methods, not just RGSS's -- confirmed for real:
# mruby 4.0 registers most of its own core methods (Array/Hash/String/
# Kernel/Numeric/...) through a declarative ROM method-table macro
# (`MRB_MT_ENTRY(fn, MRB_SYM(name), flags)`, e.g.
# 3rd/mruby/src/symbol.c's own `symbol_rom_entries` -- the exact source of
# the earlier-caught Game::Shop#name bug, Symbol#name/Class#name being two
# of the names that table form registers), a wholly different native-
# registration idiom than mruby-rgss's own literal-string
# `mrb_define_method(M, klass, "name", ...)` calls -- see bc2cpp.rb's own
# extract_native_method_names comment for both patterns it recognizes.
# Scanning the real project closed world with this list added (on top of
# mruby-rgss/src/*.cxx) found 8 further real collisions beyond the 6 RGSS
# ones already fixed (:<<, :delete, :print, :puts, :resume, :start,
# :ungetbyte, :write) -- e.g. LCF::Array1D#delete vs. core Array#delete/
# Hash#delete, exactly the same unsoundness class, just against mruby's
# own standard library instead of RGSS.
#
# The core mrbgem list mirrors every core mrbgem this project's own
# real, whole-program closed world actually loads at runtime -- NOT just
# build_config.rb's own *explicit* `conf.gem core: 'mruby-xxx'` calls, a
# real, previously-undiscovered under-approximation this adversarial
# sweep found and fixed (docs/adr/0139's own round-29 follow-up): a core
# mrbgem pulled in only *transitively*, via some other active gem's own
# `add_dependency`, is exactly as real and exactly as much a native-name
# collision risk as one `build_config.rb` names directly -- the whole
# point of this list is soundness against the real running mrb_state,
# which has no notion of "declared directly" vs. "pulled in as a
# dependency". Confirmed each of the 8 gems below is genuinely active in
# this project's real host build by reading every real `add_dependency`
# chain directly (not assumed from a gem's name alone): `mruby-lcf`'s own
# `mrbgem.rake` directly depends on `mruby-pack`/`mruby-string-ext`;
# `mruby-rgss`'s own depends on `mruby-pack`; `mruby-marshal`'s own
# (`3rd/mruby-marshal/mrbgem.rake`, an explicit top-level gem in
# `build_config.rb`'s own `explicit_shared_names`) depends on
# `mruby-struct`/`mruby-string-ext`/`mruby-metaprog`; and
# `mruby-rpgxp`'s own -- one of `rpg_maker_gem_dispatch`'s own
# `maker_gem_names`, always active in this project's real desktop/host
# build -- depends on `mruby-eval` (which itself depends on
# `mruby-binding`) and directly on `mruby-pack`/`mruby-fiber`/etc.,
# with `build_config.rb`'s own comment on `rpg_maker_gem_dispatch`
# separately confirming "the Binding/Method/Proc-ext trio mruby-rpgxp's
# own eval dependency pulls in". Scanning the real, current closed world
# with these 8 added (on top of the already-covered 15 direct `core:`
# gems) found exactly 4 more real MONO->POLY flips (`:members`, `:owner`,
# `:parameters`, `:string`) -- confirmed by hand each one is a real
# bytecode owner's own `attr_reader`-installed accessor (an `irep: nil`
# synthetic `MethodDef`, `RPG2k::Scene::Battle#owner`/`LCF::EventCommand#
# parameters`/`#string`/`Game::Troop#members`), so `monomorphic_target`'s
# own `return nil unless defs.first.irep` guard already refused to treat
# any of them as a direct-call target regardless of this fix -- real,
# verified-sound, zero *live* effect today, the same "confirmed not
# currently exploitable" bucket this file's own many prior native-
# registry fixes already document, not a live bug found by this one.
# `mruby-compiler`/`mruby-enumerator` were checked too (both genuinely
# active) and correctly excluded: `mruby-compiler` defines zero runtime
# methods at all (it's the parser/codegen, confirmed by grepping its own
# `src/*.c` for `mrb_define_method`/`MRB_MT_ENTRY`/`mrb_define_method_id`
# -- zero matches), and `mruby-enumerator` defines its own methods
# entirely in Ruby (`mrbgems/mruby-enumerator/mrblib/enumerator.rb`, no
# `src/*.c` at all) -- a real, different-shaped gap (bytecode-defined
# core stdlib invisible to the registry from *either* direction, not a
# native-method one `core_native_srcs` can close), the same already-
# documented, deliberately-left-open "Enumerable bytecode-stdlib
# registry blind spot" this file's own round-27 follow-up already names
# and re-checks, just one gem wider than previously spelled out.
#
# The core mrbgem list mirrors every core mrbgem actually active in this
# project's own real build (both direct `conf.gem core:` calls and every
# gem reachable from them or from `mruby-marshal`'s/`mruby-rpgxp`'s own
# `add_dependency` chains) -- keep it in sync if either changes.
# `mruby-fiber`'s Fiber#resume/#start don't collide with either compiled
# gem's own current target classes, but a class outside today's two
# compiled gems already collided with them (RPG2k::Scene::Menu/Battle),
# which is exactly the kind of program-wide fact only a real closed-world
# scan like this can catch.
def core_native_srcs(mruby_root)
  Dir["#{mruby_root}/src/*.c"] +
    Dir["#{mruby_root}/mrbgems/mruby-{array-ext,hash-ext,enum-ext,io,dir," \
        'numeric-ext,range-ext,fiber,exit,sprintf,kernel-ext,random,math,time,bigint,' \
        "binding,eval,metaprog,method,pack,proc-ext,string-ext,struct}/**/*.c"]
end

# The three external (non-`3rd/mruby/mrbgems`) mrbgems this project always
# loads -- `mruby-marshal`/`mruby-onig-regexp` are explicit, always-active
# top-level gems in `build_config.rb`'s own `explicit_shared_names`, and
# `mruby-stringio` is a real dependency of `mruby-wolf` (one of
# `rpg_maker_gem_dispatch`'s own `maker_gem_names`, always compiled into
# this project's real desktop/host build). Each lives in its own separate
# submodule under this repo's own `3rd/`, outside `mruby_root`
# (`3rd/mruby`) entirely, so `core_native_srcs` above can never reach them
# regardless of its own gem list -- the same real native-registry-
# soundness gap as every core mrbgem `core_native_srcs` itself exists to
# close, just one directory level further out. `mruby-marshal`'s own
# source is `.cpp`, not `.c` (this project's own C++ port, `src/
# marshal.cpp`), unlike the other two. Found and fixed alongside
# `core_native_srcs`'s own round-29 fix (see its comment for the full
# writeup and the real, confirmed-not-live flip this uncovered:
# `LCF::EventCommand#string` colliding with `StringIO#string`/`IO`-family
# methods this scan adds).
def external_gem_native_srcs(gems_root)
  Dir["#{gems_root}/3rd/mruby-marshal/src/*.cpp"] +
    Dir["#{gems_root}/3rd/mruby-onig-regexp/src/*.c"] +
    Dir["#{gems_root}/3rd/mruby-stringio/src/*.c"]
end

# The whole-program mrblib source set (every gem's own real Ruby source,
# not just this compiled gem's own owners) that every one of
# mruby-lcf-compiled's/mruby-rpg2k-compiled's/mruby-rgss-compiled's own
# mrbgem.rake calls feed into bc2cpp.rb as `closed_world_srcs`, so
# `build_registry`'s own MONO/POLY resolution sees every gem that could
# define a colliding method name -- see mruby-lcf-compiled/mrbgem.rake's
# own comment for the full reasoning (`LCF::Database#rpg2003?` looking
# MONO in isolation when the real whole program also defines
# `Game::Actor`/`Party`/`Battle#rpg2003?`).
#
# Extracted here, rather than left as the three byte-identical
# `Dir[...] + Dir[...] + Dir[...]` literals each mrbgem.rake used to carry
# on its own (confirmed byte-identical across all three files, not
# assumed, by a dedicated bug-hunt round's own cross-gem-devirtualization-
# soundness audit -- see docs/adr/0139's own follow-up), for the exact
# same drift-risk reason `BC2CPP_COMPILED_GEMS` above and
# `core_native_srcs` were already centralized: nothing forces three
# hand-duplicated literals to stay in sync. Unlike a stale owners list or
# a stale `NATIVE_SRCS` (both already fixed to read from one shared
# place), a drifted closed-world mrblib set would fail *silently* -- Rake
# has no way to notice that gem A's own registry now sees a different
# whole program than gem B's, so two compiled gems could reach genuinely
# different MONO/POLY conclusions for the same method name with no build
# error at all, reintroducing exactly the soundness gap this whole
# mechanism (OTHER_OWNERS/OTHER_DECLS_HEADER) exists to close. Not a live
# bug today -- the three literals were confirmed identical before this
# change -- but a real, previously-unenforced invariant, now enforced by
# construction instead of by three separate authors each copying the
# other two correctly forever.
def closed_world_mrblib_srcs(gems_root)
  Dir["#{gems_root}/mruby-rpg2k/mrblib/**/*.rb"] +
    Dir["#{gems_root}/mruby-lcf/mrblib/*.rb"] +
    Dir["#{gems_root}/mruby-rgss/mrblib/*.rb"]
end
