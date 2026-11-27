state = NfcxxState.new
state.add("flags", "-O2", "-g")
state.add("empty")
state.add("flags", "duplicate")
state.add("unicode", "日本語", "\xff")
state.get("flags") << "--extra"
[state.names, state.get("flags"), state.get("missing"), state.get("empty"), state.records]
