# Appended after optcarrot's own files: the headless benchmark of `optcarrot --benchmark`, frame count from ARGV[1].
nes = Optcarrot::NES.new(
  romfile: ARGV[0] || "examples/Lan_Master.nes",
  video: :none,
  audio: :none,
  input: :none,
  frames: (ARGV[1] || "180").to_i,
  print_fps: true,
  print_video_checksum: true,
)
nes.run
