# Inventory GCC directives without pretending to implement the DejaGnu harness.
# Usage: scripts/mrb gcc-index.rb SNAPSHOT FILELIST
root, list = ARGV
puts "page\taction\tstandard\tclassification\treason"
paths = File.open(list, 'rb') { |f| f.read.split("\n") }
paths.each do |path|
  text = File.open(root + '/' + path, 'rb') { |f| f.read }
  directives = text.split("\n").select { |line| line.include?('dg-') }
  action = '-'; standard = '-'; classification = 'needs-harness'; reason = 'directives or implicit defaults need the native harness'
  if directives.size == 1
    directive = directives[0]
    ['11', '14', '17', '20', '23'].each do |mode|
      ['run', 'compile'].each do |kind|
        if directive.include?('{ dg-do ' + kind + ' { target c++' + mode + ' } }')
          action = kind; standard = 'c++' + mode
          classification = 'simple-positive'; reason = 'only an explicit action and standard selector; review auxiliary inputs before execution'
        end
      end
    end
  end
  puts [path, action, standard, classification, reason].join("\t")
end
