class_name DeviceLink
extends Node
## Sends saved videos between FrameTube copies on the same home network, e.g. the PC and the Steam
## Frame. Downloads made on the PC can go straight to the Frame (the PC downloads, which is faster,
## then the file goes over Wi-Fi), and anything in the Downloads list can be sent across.
##
## Finding each other: every FrameTube says "I'm here" by UDP broadcast every few seconds (port
## DISCOVERY_PORT) and listens for the others. Sending: a plain TCP connection to the receiver's
## SERVICE_PORT carrying one JSON line (what's coming), then the files' bytes, then one JSON line back.
##
## Trust: the first time a device sends, the receiver asks "Allow videos from <name>?" on its own
## menu (PIN-protected when the parental lock is on). The sender picks a random secret for that
## receiver and sends it with every transfer; once allowed, the receiver only accepts that secret
## from that device. Nothing else is ever accepted: received files go only into the Downloads folder,
## under names the receiver makes up itself, and only when there's room.
##
## Transfers wait while the other device isn't around (both need FrameTube open on the same network)
## and start by themselves when it shows up.

signal changed # peers, trust, or a transfer's progress changed
signal message(text: String) # for the status line
signal ask(id: String, name: String) # an unknown device wants to send: main shows Allow / Not now

const DISCOVERY_PORT := 47811
const SERVICE_PORT := 47812
const ANNOUNCE_EVERY := 2.5
const ONLINE_FOR := 9.0 # seconds since the last "I'm here" that a device counts as around
const CHUNK := 1 << 20
const RECV_PER_FRAME := 8 << 20
const IDLE_TIMEOUT := 30.0
const SPACE_MARGIN := 300 << 20
const VIDEO_EXTS := ["mkv", "mp4", "webm", "mov", "m4v"]

var store: Store
var downloads: Downloads
var enabled := true # receive videos from other devices (sending always works)
var my_id := ""
var my_name := ""
var my_kind := "" # "frame" | "pc"
var port := SERVICE_PORT
var peers := {} # id -> {id, name, kind, ip, port, seen (0 = only remembered)}
var sending := {} # video id -> {peer, name, percent, thread, cancel: Array[bool], state}

## Test hooks
var bind_address := "*"
var discovery := true
var extra_peers: Array = [] # "ip:port" to ask directly (when broadcasts can't be used)

var _server := TCPServer.new()
var _udp_in := PacketPeerUDP.new()
var _udp_out := PacketPeerUDP.new()
var _announce_t := 0.0
var _scan_t := 0.0
var _incoming: Array = [] # receiving connections
var _pending_ask := {} # id -> {name, secret}: waiting for the user's answer
var _retry_at := {} # video id -> time before trying again
var _known_hello := {} # "ip:port" -> next hello time (extra_peers)
var _hello_threads: Array[Thread] = []


func setup(p_store: Store, p_downloads: Downloads) -> void:
	store = p_store
	downloads = p_downloads
	my_id = str(store.get_setting("link_id", ""))
	if my_id.length() != 16:
		my_id = _random_hex(8)
		store.set_setting("link_id", my_id)
	my_kind = "frame" if OS.get_name() == "Linux" and Engine.get_architecture_name().begins_with("arm") else "pc"
	my_name = "Steam Frame" if my_kind == "frame" else _computer_name()
	enabled = bool(store.get_setting("link_receive", true))
	var known = store.get_setting("link_known", {})
	if known is Dictionary:
		for id in known:
			var k = known[id]
			if k is Dictionary:
				peers[id] = {"id": id, "name": str(k.get("name", "FrameTube")), "kind": str(k.get("kind", "pc")),
					"ip": str(k.get("ip", "")), "port": int(k.get("port", SERVICE_PORT)), "seen": 0.0}


func start() -> void:
	for p in range(port, port + 6): # another program might have the port
		if _server.listen(p, bind_address) == OK:
			port = p
			break
	if not _server.is_listening():
		printerr("[link] couldn't open a port to receive videos")
	if discovery:
		_udp_out.set_broadcast_enabled(true)
		if _udp_in.bind(DISCOVERY_PORT, "*") != OK:
			printerr("[link] discovery port is busy; other devices won't be found automatically")


## "This PC" / "This Steam Frame"
func here_label() -> String:
	return "This Steam Frame" if my_kind == "frame" else "This PC"


func is_online(id: String) -> bool:
	return peers.has(id) and float(peers[id].seen) > 0.0 and now() - float(peers[id].seen) < ONLINE_FOR


func peer_name(id: String) -> String:
	return str(peers[id].name) if peers.has(id) else "the other device"


## For small buttons: "Frame" / "PC".
func short_name(id: String) -> String:
	return "Frame" if peers.has(id) and peers[id].kind == "frame" else "PC"


## Devices to offer under "Save downloads to", Steam Frames first, then by name.
func peer_list() -> Array:
	var l := peers.values()
	l.sort_custom(func(a, b): return [a.kind != "frame", a.name] < [b.kind != "frame", b.name])
	return l


## Who is allowed to send to this device: id -> {name, secret}.
func trusted() -> Dictionary:
	var t = store.get_setting("link_trusted", {})
	return t if t is Dictionary else {}


func forget_all() -> void:
	store.set_setting("link_trusted", {})
	changed.emit()


## Answer to ask(): allowed or not. A "no" lasts until FrameTube restarts (the sender keeps waiting).
func answer(id: String, allow: bool) -> void:
	if not _pending_ask.has(id):
		return
	var a: Dictionary = _pending_ask[id]
	if allow:
		var t := trusted()
		t[id] = {"name": a.name, "secret": a.secret}
		store.set_setting("link_trusted", t)
		message.emit("%s can now send videos here." % a.name)
		_pending_ask.erase(id)
	else:
		a.denied = true
		message.emit("Not accepting videos from %s." % a.name)
	changed.emit()


## Short text for a video's button while it's on its way somewhere ("" = not being sent).
func send_label(vid: String) -> String:
	if not downloads.items.has(vid):
		return ""
	var to := str(downloads.items[vid].get("send_to", ""))
	if to == "":
		return ""
	if sending.has(vid):
		var s: Dictionary = sending[vid]
		if s.state == "ask":
			return "Allow it there"
		return "Sending %d%%" % int(s.percent)
	return "Waiting for " + short_name(to)


## Longer text for the Downloads list.
func send_detail(vid: String) -> String:
	var to := str(downloads.items[vid].get("send_to", ""))
	var name := peer_name(to)
	if sending.has(vid):
		var s: Dictionary = sending[vid]
		if s.state == "ask":
			return "Waiting for you to press Allow in FrameTube on %s" % name
		return "Sending to %s · %d%%" % [name, int(s.percent)]
	return "Goes to %s when FrameTube is open there (same Wi-Fi)" % name


static func now() -> float:
	return Time.get_ticks_msec() / 1000.0


# --- Main loop ---------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if discovery:
		_announce_t -= delta
		if _announce_t <= 0.0:
			_announce_t = ANNOUNCE_EVERY
			_announce()
		_listen_discovery()
	for addr in extra_peers:
		if now() >= float(_known_hello.get(addr, 0.0)):
			_known_hello[addr] = now() + 3.0
			_hello(str(addr))
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = 1.0
		_start_sends()
	_accept()
	for c in _incoming.duplicate():
		_serve(c)


func _exit_tree() -> void:
	for vid in sending:
		sending[vid].cancel[0] = true
	for vid in sending.keys():
		var th: Thread = sending[vid].thread
		if th and th.is_started():
			th.wait_to_finish()
	for th in _hello_threads:
		th.wait_to_finish()
	_hello_threads.clear()
	for c in _incoming.duplicate():
		_drop(c, false)
	_server.stop()


# --- Finding each other ---------------------------------------------------------------------------

func _announce() -> void:
	var pkt := JSON.stringify({"app": "FrameTube", "v": 1, "id": my_id, "name": my_name, "kind": my_kind,
		"port": port}).to_utf8_buffer()
	var targets := ["255.255.255.255"]
	for a in IP.get_local_addresses(): # also each network's own broadcast address (more reliable on Windows)
		if a.count(".") == 3 and _is_private(a):
			var b := a.get_slice(".", 0) + "." + a.get_slice(".", 1) + "." + a.get_slice(".", 2) + ".255"
			if not targets.has(b):
				targets.append(b)
	for t in targets:
		_udp_out.set_dest_address(t, DISCOVERY_PORT)
		_udp_out.put_packet(pkt)


func _listen_discovery() -> void:
	if not _udp_in.is_bound():
		return
	while _udp_in.get_available_packet_count() > 0:
		var pkt := _udp_in.get_packet()
		var ip := _udp_in.get_packet_ip()
		var d = JSON.parse_string(pkt.get_string_from_utf8())
		if d is Dictionary and d.get("app") == "FrameTube":
			_saw(d, ip)


func _saw(d: Dictionary, ip: String) -> void:
	var id := str(d.get("id", ""))
	if id == my_id or id.length() != 16 or ip == "":
		return
	var p: Dictionary = peers.get(id, {})
	var fresh: bool = p.is_empty() or float(p.get("seen", 0.0)) == 0.0 or now() - float(p.get("seen", 0.0)) > ONLINE_FOR
	var info := {"id": id, "name": str(d.get("name", "FrameTube")).left(40), "kind": "frame" if d.get("kind") == "frame" else "pc",
		"ip": ip, "port": clampi(int(d.get("port", SERVICE_PORT)), 1024, 65535), "seen": now()}
	var moved: bool = p.is_empty() or p.ip != info.ip or p.port != info.port or p.name != info.name
	peers[id] = info
	if moved:
		var known = store.get_setting("link_known", {})
		if not (known is Dictionary):
			known = {}
		# Same device under a new identity (FrameTube reinstalled there): forget the old one.
		for old in peers.keys():
			if old != id and peers[old].name == info.name and peers[old].kind == info.kind and not is_online(old):
				peers.erase(old)
				known.erase(old)
				if str(store.get_setting("save_to", "")) == old:
					store.set_setting("save_to", id)
				for vid in downloads.items:
					if str(downloads.items[vid].get("send_to", "")) == old:
						downloads.items[vid].send_to = id
		known[id] = {"name": info.name, "kind": info.kind, "ip": info.ip, "port": info.port}
		store.set_setting("link_known", known)
	if fresh:
		changed.emit()


## For devices given by address: a short "who are you?" in a thread.
func _hello(addr: String) -> void:
	var th := Thread.new()
	_hello_threads.append(th)
	th.start(func():
		var ip := addr.get_slice(":", 0)
		var p := int(addr.get_slice(":", 1))
		var tcp := _connect(ip, p, 3.0)
		var r := {}
		if tcp:
			tcp.put_data((JSON.stringify({"op": "hello"}) + "\n").to_utf8_buffer())
			r = _read_line(tcp, 5.0, [false])
			tcp.disconnect_from_host()
		_hello_done.call_deferred(th, r, ip))


func _hello_done(th: Thread, r: Dictionary, ip: String) -> void:
	if not _hello_threads.has(th):
		return # already waited for on exit
	_hello_threads.erase(th)
	th.wait_to_finish()
	if r.get("app") == "FrameTube":
		_saw(r, ip)


# --- Sending ----------------------------------------------------------------------------------------

func _start_sends() -> void:
	for vid in downloads.items:
		var e: Dictionary = downloads.items[vid]
		var to := str(e.get("send_to", ""))
		if to == "" or sending.has(vid) or now() < float(_retry_at.get(vid, 0.0)):
			continue
		if not peers.has(to) or str(peers[to].ip) == "":
			continue
		if not is_online(to):
			# Not heard from it lately: still try its last address now and then (broadcasts get lost).
			_retry_at[vid] = now() + 20.0
		_send(vid, to)


func _send(vid: String, to: String) -> void:
	var e: Dictionary = downloads.items[vid]
	var files := [{"path": str(e.file), "kind": "video"}]
	for t in e.get("subs", []):
		if FileAccess.file_exists(str(t.url)):
			files.append({"path": str(t.url), "kind": "sub", "code": str(t.code), "name": str(t.name), "auto": bool(t.get("auto", false))})
	var header := {"op": "send", "from": my_id, "name": my_name, "kind": my_kind, "port": port,
		"secret": _secret_for(to), "item": _public_item(e), "files": []}
	for f in files:
		var g: Dictionary = f.duplicate()
		g.erase("path")
		g.size = Downloads._file_size(f.path)
		g.ext = str(f.path).get_extension().to_lower()
		header.files.append(g)
	var s := {"peer": to, "percent": 0.0, "state": "connecting", "cancel": [false], "thread": Thread.new()}
	sending[vid] = s
	s.thread.start(_send_thread.bind(vid, str(peers[to].ip), int(peers[to].port), header,
		files.map(func(f): return f.path), s.cancel))
	changed.emit()


## Worker thread. Result keys: ok, why (refused: "ask" | "denied" | "off" | "space" | "busy" | "have"), error.
func _send_thread(vid: String, ip: String, p: int, header: Dictionary, paths: Array, cancel: Array) -> void:
	var tcp := _connect(ip, p, 5.0)
	if tcp == null:
		_send_done.call_deferred(vid, {"error": "offline"})
		return
	tcp.put_data((JSON.stringify(header) + "\n").to_utf8_buffer())
	var r := _read_line(tcp, 15.0, cancel)
	if r.get("why") == "ask":
		_send_state.call_deferred(vid, "ask")
		r = _read_line(tcp, 600.0, cancel) # the answer comes on the same connection
	if not r.get("ok", false):
		tcp.disconnect_from_host()
		_send_done.call_deferred(vid, r if not r.is_empty() else {"error": "no answer"})
		return
	_send_state.call_deferred(vid, "sending")
	var total := 0
	for f in header.files:
		total += int(f.size)
	var sent := 0
	var last_report := 0.0
	for path in paths:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			tcp.disconnect_from_host()
			_send_done.call_deferred(vid, {"error": "file missing"})
			return
		while not f.eof_reached():
			if cancel[0]:
				tcp.disconnect_from_host()
				_send_done.call_deferred(vid, {"error": "cancelled"})
				return
			var buf := f.get_buffer(CHUNK)
			if buf.is_empty():
				break
			if tcp.put_data(buf) != OK or tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_send_done.call_deferred(vid, {"error": "connection lost"})
				return
			sent += buf.size()
			if now() - last_report > 0.25:
				last_report = now()
				_send_progress.call_deferred(vid, 100.0 * sent / maxf(total, 1.0))
	r = _read_line(tcp, 120.0, cancel)
	tcp.disconnect_from_host()
	_send_done.call_deferred(vid, r if not r.is_empty() else {"error": "no answer"})


func _send_state(vid: String, state: String) -> void:
	if sending.has(vid):
		sending[vid].state = state
		changed.emit()


func _send_progress(vid: String, pct: float) -> void:
	if sending.has(vid):
		sending[vid].percent = pct
		changed.emit()


func _send_done(vid: String, r: Dictionary) -> void:
	if not sending.has(vid):
		return
	var s: Dictionary = sending[vid]
	s.thread.wait_to_finish()
	sending.erase(vid)
	var name := peer_name(s.peer)
	var e: Dictionary = downloads.items.get(vid, {})
	var title := str(e.get("title", "the video"))
	if r.get("ok", false) or r.get("why") == "have":
		if not e.is_empty():
			if bool(e.get("send_move", false)):
				downloads.remove(vid) # it was only here on its way to the other device
			else:
				downloads.clear_send(vid)
		message.emit("Sent \"%s\" to %s." % [title, name] if r.get("ok", false) else "%s already has \"%s\"." % [name, title])
	elif not s.cancel[0]:
		var why := str(r.get("why", ""))
		_retry_at[vid] = now() + (60.0 if why == "space" or why == "denied" or why == "off" else 8.0)
		match why:
			"space": message.emit("%s doesn't have room for \"%s\" (it needs %s free). Will try again." % [name, title, Downloads.size_text(int(r.get("need", 0)))])
			"denied": message.emit("%s said no to videos from here. Will ask again later." % name)
			"off": message.emit("%s isn't accepting videos (Settings > Receive videos). Will try again." % name)
		if r.has("error") and r.error != "offline" and r.error != "no answer":
			printerr("[link] send failed: ", r.error)
	changed.emit()


func cancel_send(vid: String) -> void:
	if sending.has(vid):
		sending[vid].cancel[0] = true


## What the receiver gets to know about the video (no local paths).
static func _public_item(e: Dictionary) -> Dictionary:
	var d := {}
	for k in ["id", "url", "title", "channel", "views", "duration", "width", "height", "fps", "vcodec", "projection", "age_limit"]:
		d[k] = e.get(k)
	return d


func _secret_for(to: String) -> String:
	var s = store.get_setting("link_secrets", {})
	if not (s is Dictionary):
		s = {}
	if not s.has(to):
		s[to] = _random_hex(16)
		store.set_setting("link_secrets", s)
	return str(s[to])


# --- Receiving --------------------------------------------------------------------------------------

func _accept() -> void:
	while _server.is_listening() and _server.is_connection_available():
		var tcp := _server.take_connection()
		if _incoming.size() >= 4:
			tcp.disconnect_from_host()
			continue
		_incoming.append({"tcp": tcp, "state": "header", "buf": PackedByteArray(), "t": now()})


func _serve(c: Dictionary) -> void:
	var tcp: StreamPeerTCP = c.tcp
	tcp.poll()
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_drop(c, false)
		return
	match c.state:
		"header":
			var n := tcp.get_available_bytes()
			if n > 0:
				c.buf.append_array(tcp.get_partial_data(mini(n, 65536))[1])
				c.t = now()
			var nl: int = c.buf.find(10)
			if nl < 0:
				if c.buf.size() > 65536 or now() - c.t > 10.0:
					_drop(c, false)
				return
			var line: PackedByteArray = c.buf.slice(0, nl)
			c.rest = c.buf.slice(nl + 1)
			var h = JSON.parse_string(line.get_string_from_utf8())
			_on_header(c, h if h is Dictionary else {})
		"ask": # waiting for the user to press Allow / Not now
			if trusted().has(c.from):
				_begin_receive(c)
			elif not _pending_ask.has(c.from) or _pending_ask[c.from].get("denied", false):
				_reply(c, {"ok": false, "why": "denied"})
				_drop(c, false)
		"body":
			_receive(c)
		"done":
			if now() - c.t > 2.0:
				_drop(c, false)


func _on_header(c: Dictionary, h: Dictionary) -> void:
	if h.get("op") == "hello":
		_reply(c, {"app": "FrameTube", "v": 1, "id": my_id, "name": my_name, "kind": my_kind, "port": port})
		_drop(c, false)
		return
	if h.get("op") != "send":
		_drop(c, false)
		return
	var from := str(h.get("from", ""))
	var name := str(h.get("name", "Another device")).left(40)
	var secret := str(h.get("secret", ""))
	var item = h.get("item")
	var files = h.get("files")
	if from.length() != 16 or secret.length() != 32 or not (item is Dictionary) or not (files is Array) or files.is_empty():
		_drop(c, false)
		return
	if not enabled:
		_reply(c, {"ok": false, "why": "off"})
		_drop(c, false)
		return
	# Remember where it is (so "Save downloads to" can offer it back).
	_saw({"id": from, "name": name, "kind": h.get("kind", "pc"), "port": h.get("port", SERVICE_PORT)}, c.tcp.get_connected_host())
	var vid := str(item.get("id", ""))
	if not RegEx.create_from_string("^[A-Za-z0-9_-]{11}$").search(vid):
		_drop(c, false)
		return
	if downloads.has(vid):
		_reply(c, {"ok": false, "why": "have"})
		_drop(c, false)
		return
	if _receiving(vid):
		_reply(c, {"ok": false, "why": "busy"})
		_drop(c, false)
		return
	# Check every file and decide where it goes before anything is written.
	var plan := []
	var total := 0
	var base := Downloads.folder().path_join("%s [%s]" % [_safe_name(str(item.get("title", vid))), vid])
	var codes := {}
	for f in files:
		if not (f is Dictionary):
			_drop(c, false)
			return
		var size := int(f.get("size", -1))
		var ext := str(f.get("ext", "")).to_lower()
		if size < 0:
			_drop(c, false)
			return
		if plan.is_empty():
			if f.get("kind") != "video" or not VIDEO_EXTS.has(ext):
				_drop(c, false)
				return
			plan.append({"dest": base + "." + ext, "size": size, "kind": "video"})
		else:
			if f.get("kind") != "sub" or ext != "json3" or size > (16 << 20):
				_drop(c, false)
				return
			var code := _safe_code(str(f.get("code", "")))
			var auto := bool(f.get("auto", false))
			var key := code + ("-auto" if auto else "")
			var dest := "%s.%s.json3" % [base, key]
			codes[key] = int(codes.get(key, 0)) + 1
			if codes[key] > 1:
				dest = "%s.%s-%d.json3" % [base, key, codes[key]]
			plan.append({"dest": dest, "size": size, "kind": "sub", "code": code, "auto": auto,
				"name": str(f.get("name", code)).left(60)})
		total += size
	var free := DirAccess.open(Downloads.folder()).get_space_left() if DirAccess.open(Downloads.folder()) else 0
	if free > 0 and free < total + SPACE_MARGIN:
		_reply(c, {"ok": false, "why": "space", "need": total + SPACE_MARGIN})
		_drop(c, false)
		return
	c.from = from
	c.name = name
	c.item = item
	c.plan = plan
	c.total = total
	var t := trusted()
	if t.has(from):
		if str(t[from].get("secret", "")) != secret:
			_reply(c, {"ok": false, "why": "denied"}) # someone pretending to be that device
			_drop(c, false)
			return
		_begin_receive(c)
		return
	if _pending_ask.has(from) and _pending_ask[from].get("denied", false):
		_reply(c, {"ok": false, "why": "denied"})
		_drop(c, false)
		return
	var first := not _pending_ask.has(from)
	if first and _pending_ask.size() >= 3: # don't let a crowd of unknown devices pile up questions
		_reply(c, {"ok": false, "why": "denied"})
		_drop(c, false)
		return
	_pending_ask[from] = {"name": name, "secret": secret}
	c.state = "ask"
	_reply(c, {"ok": false, "why": "ask"})
	if first:
		ask.emit(from, name)


func _receiving(vid: String) -> bool:
	for c in _incoming:
		if c.has("item") and str(c.item.get("id", "")) == vid:
			return c.state == "body"
	return false


func _begin_receive(c: Dictionary) -> void:
	c.state = "body"
	c.index = -1
	c.got = 0
	c.t = now()
	_reply(c, {"ok": true})
	_next_file(c)
	var leftover: PackedByteArray = c.get("rest", PackedByteArray())
	c.rest = PackedByteArray()
	if not leftover.is_empty():
		_write(c, leftover)
	message.emit("Receiving \"%s\" from %s..." % [str(c.item.get("title", "a video")), c.name])
	changed.emit()


func _next_file(c: Dictionary) -> void:
	if c.has("file") and c.file:
		c.file.close()
	c.index += 1
	c.left = 0
	if c.index >= c.plan.size():
		_finish_receive(c)
		return
	var p: Dictionary = c.plan[c.index]
	c.file = FileAccess.open(p.dest + ".part", FileAccess.WRITE)
	c.left = int(p.size)
	if c.file == null:
		_drop(c, true)
	elif c.left == 0:
		_next_file(c)


func _receive(c: Dictionary) -> void:
	var budget := RECV_PER_FRAME
	while budget > 0 and c.state == "body":
		var n: int = mini(c.tcp.get_available_bytes(), mini(budget, CHUNK))
		if n <= 0:
			if now() - c.t > IDLE_TIMEOUT:
				_drop(c, true)
			return
		var r: Array = c.tcp.get_partial_data(n)
		if r[0] != OK:
			_drop(c, true)
			return
		c.t = now()
		budget -= r[1].size()
		_write(c, r[1])


func _write(c: Dictionary, data: PackedByteArray) -> void:
	var off := 0
	while off < data.size() and c.state == "body":
		var take: int = mini(c.left, data.size() - off)
		c.file.store_buffer(data.slice(off, off + take) if take < data.size() or off > 0 else data)
		off += take
		c.left -= take
		c.got += take
		if c.left <= 0:
			_next_file(c)


func _finish_receive(c: Dictionary) -> void:
	var video := ""
	var subs := []
	for p in c.plan:
		var dest: String = p.dest
		DirAccess.remove_absolute(dest)
		if DirAccess.rename_absolute(dest + ".part", dest) != OK:
			_drop(c, true)
			return
		if p.kind == "video":
			video = dest
		else:
			subs.append({"code": p.code, "name": p.name, "auto": p.auto, "url": dest})
	downloads.import_item(c.item, video, subs)
	c.state = "done"
	c.t = now()
	_reply(c, {"ok": true, "done": true})
	message.emit("Got \"%s\" from %s. It's in Downloads." % [str(c.item.get("title", "a video")), c.name])
	changed.emit()


func _reply(c: Dictionary, d: Dictionary) -> void:
	c.tcp.put_data((JSON.stringify(d) + "\n").to_utf8_buffer())


func _drop(c: Dictionary, clean: bool) -> void:
	if c.has("file") and c.file:
		c.file.close()
		c.file = null
	if clean and c.has("plan"):
		for p in c.plan:
			DirAccess.remove_absolute(str(p.dest) + ".part")
		message.emit("Receiving \"%s\" from %s stopped part-way. It'll be sent again." % [str(c.item.get("title", "a video")), c.name])
	c.tcp.disconnect_from_host()
	c.state = "closed"
	_incoming.erase(c)
	changed.emit()


# --- Helpers ----------------------------------------------------------------------------------------

## Blocking connect for worker threads; null if it doesn't answer in time.
static func _connect(ip: String, p: int, timeout: float) -> StreamPeerTCP:
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host(ip, p) != OK:
		return null
	var t0 := now()
	while now() - t0 < timeout:
		tcp.poll()
		match tcp.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				tcp.set_no_delay(true)
				return tcp
			StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE:
				return null
		OS.delay_msec(20)
	tcp.disconnect_from_host()
	return null


## One JSON line from the other side (worker threads), or {} on timeout / disconnect.
static func _read_line(tcp: StreamPeerTCP, timeout: float, cancel: Array) -> Dictionary:
	var buf := PackedByteArray()
	var t0 := now()
	while now() - t0 < timeout and not cancel[0]:
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var n := tcp.get_available_bytes()
		if n > 0:
			var r := tcp.get_partial_data(n)
			buf.append_array(r[1])
			var nl := buf.find(10)
			if nl >= 0:
				var d = JSON.parse_string(buf.slice(0, nl).get_string_from_utf8())
				return d if d is Dictionary else {}
			if buf.size() > 65536:
				break
		else:
			OS.delay_msec(20)
	return {}


static func _safe_name(s: String) -> String:
	var out := ""
	for ch in s:
		out += "_" if "<>:\"/\\|?*".contains(ch) or ch.unicode_at(0) < 32 else ch
	out = out.strip_edges().trim_suffix(".").left(80).strip_edges()
	while out.begins_with("."):
		out = out.substr(1)
	return out if out != "" else "video"


static func _safe_code(s: String) -> String:
	var out := ""
	for ch in s.left(16):
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "-":
			out += ch
	return out if out != "" else "xx"


static func _is_private(ip: String) -> bool:
	return ip.begins_with("192.168.") or ip.begins_with("10.") or \
		(ip.begins_with("172.") and int(ip.get_slice(".", 1)) >= 16 and int(ip.get_slice(".", 1)) <= 31)


static func _random_hex(n_bytes: int) -> String:
	return Crypto.new().generate_random_bytes(n_bytes).hex_encode()


static func _computer_name() -> String:
	var n := OS.get_environment("COMPUTERNAME")
	if n == "" and FileAccess.file_exists("/etc/hostname"):
		n = FileAccess.get_file_as_string("/etc/hostname").strip_edges()
	if n == "":
		n = "PC"
	return n

