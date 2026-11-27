# The real state library receives process arguments and binary stdin, writes a file, then copies it to stdout.
state = NfcxxState.new
state.add("arguments", *ARGV)
state.add("stdin", $stdin.read)
size = File.write(ARGV[0], state.records)
$stdout.write(File.read(ARGV[0]))
$stderr.write([size, File.exist?(ARGV[0]), File.file?(ARGV[0]), File.directory?(ARGV[0]),
               Dir.exist?(ARGV[1]), File.executable?(ARGV[1]), $0 == $PROGRAM_NAME].inspect)
