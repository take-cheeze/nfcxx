# libclang-edg through mruby: the walk of walk.c with LibclangEdg (lib/libclang-edg/mruby). Same output format.
# Usage: mruby mruby_walk.rb FILE [option]...   (the options go to the front end: -std=..., -I..., -D..., -U...)

SCOPE = %w[TranslationUnit Namespace StructDecl ClassDecl UnionDecl EnumDecl ClassTemplate]
FUNCTION = %w[FunctionDecl CXXMethod CXXConstructor CXXDestructor FunctionTemplate]
DECL = %w[VarDecl FieldDecl EnumConstantDecl TypedefDecl ParmDecl]

def position(cursor)
  "#{cursor.line}:#{cursor.column}"
end

def walk(parent, out)
  parent.children.each do |c|
    kind = c.kind
    next unless SCOPE.include?(kind) || FUNCTION.include?(kind) || DECL.include?(kind)
    next unless c.main_file?
    pkind = parent.kind
    if FUNCTION.include?(pkind)
      next unless kind == "ParmDecl"
    else
      next unless SCOPE.include?(pkind)
    end
    out << "#{kind} #{position(c)} #{c.spelling} in #{pkind}@#{position(parent)}"
    walk(c, out) if SCOPE.include?(kind) || FUNCTION.include?(kind)
  end
end

index = LibclangEdg::Index.new
tu = index.parse(ARGV[0], *ARGV[1..-1])
out = []
walk(tu.cursor, out)
puts out
