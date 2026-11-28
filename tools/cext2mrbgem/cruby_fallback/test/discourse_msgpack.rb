# A Ruby script in the style of Discourse's msgpack use. The msgpack C extension (CRuby) keeps its packer and unpacker state
# in CRuby: they are handles here. The data goes out as msgpack bytes and comes back; the round trip is checked.
data = {"topic_id" => 42, "tags" => ["ruby", "mruby"], "score" => 2.5, "closed" => false, "note" => nil}
packer = Fb.new("MessagePack::Packer")
Fb.send_h(packer, "write", data)
packed = Fb.send_h(packer, "to_s")
unpacker = Fb.new("MessagePack::Unpacker")
Fb.send_h(unpacker, "feed", packed)
back = Fb.send_h(unpacker, "read")
raise "round trip changed the data: #{back.inspect}" unless back == data
puts "packed #{packed.bytesize} bytes, round trip ok"
puts back.inspect
