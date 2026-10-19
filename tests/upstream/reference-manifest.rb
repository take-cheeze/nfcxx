# Convert extraction inventories into compile-survey tasks. Modes are explicit
# survey choices, not automatically inferred minimum standard requirements.
def die(message)
  $stderr.puts message
  exit 1
end
die('usage: reference-manifest.rb SUITE INVENTORY') unless ARGV.size == 2
suite, inventory = ARGV
die('unknown suite') unless ['cppreference', 'cpprefjp'].include?(suite)
puts "suite\tid\tpage\tstandard\tsource"
seen = {}
File.open(inventory, 'rb') do |f|
  f.read.split("\n")[1..-1].each do |line|
    id, page, number, source, output = line.split("\t", -1)
    die('duplicate example ID: ' + id) if seen[id]
    seen[id] = true
    standard = 'c++23'
    if suite == 'cpprefjp' && page.start_with?('lang/cpp')
      standard = 'c++' + page.split('/')[1].byteslice(3, 2)
    end
    puts [suite, id, page, standard, source].join("\t")
  end
end
