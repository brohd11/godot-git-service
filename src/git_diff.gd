## line-based diff helpers shared by git and the editor.
## keeps local hunks in `GitUtil.Keys` shape.

const GitUtil = preload("res://addons/_lib/git_service/src/git_util.gd")

const CONTEXT = 3

const MAX_EDIT_DISTANCE = 1024

enum _Op {
	EQUAL,
	DELETE,
	INSERT,
}


## lives in GitUtil so get_file_at_head() can reach it without a cyclic preload
static func to_lines(text:String) -> PackedStringArray:
	return GitUtil.to_lines(text)


static func diff_lines(old_lines:PackedStringArray, new_lines:PackedStringArray,
		context:=CONTEXT) -> Array[Dictionary]:
	if old_lines == new_lines:
		return []
	return _build_hunks(_diff_ops(old_lines, new_lines), old_lines, new_lines, context)


static func _diff_ops(old_lines:PackedStringArray, new_lines:PackedStringArray) -> PackedByteArray:
	var n = old_lines.size()
	var m = new_lines.size()

	var prefix = 0
	var min_len = mini(n, m)
	while prefix < min_len and old_lines[prefix] == new_lines[prefix]:
		prefix += 1

	var suffix = 0
	while suffix < min_len - prefix and old_lines[n - 1 - suffix] == new_lines[m - 1 - suffix]:
		suffix += 1

	var mid_old = old_lines.slice(prefix, n - suffix)
	var mid_new = new_lines.slice(prefix, m - suffix)

	var mid:PackedByteArray = PackedByteArray()
	if mid_old.is_empty():
		mid = _fill_ops(_Op.INSERT, mid_new.size())
	elif mid_new.is_empty():
		mid = _fill_ops(_Op.DELETE, mid_old.size())
	else:
		mid = _myers(mid_old, mid_new)
		if mid.is_empty():
			mid = _fill_ops(_Op.DELETE, mid_old.size())
			mid.append_array(_fill_ops(_Op.INSERT, mid_new.size()))

	var ops = _fill_ops(_Op.EQUAL, prefix)
	ops.append_array(mid)
	ops.append_array(_fill_ops(_Op.EQUAL, suffix))
	return ops


static func _fill_ops(op:_Op, count:int) -> PackedByteArray:
	var ops = PackedByteArray()
	ops.resize(count)
	ops.fill(op)
	return ops


static func _myers(old_lines:PackedStringArray, new_lines:PackedStringArray) -> PackedByteArray:
	var ids = {}
	var a = _intern(old_lines, ids)
	var b = _intern(new_lines, ids)

	var n = a.size()
	var m = b.size()
	var budget = mini(n + m, MAX_EDIT_DISTANCE)

	var offset = budget + 1
	var v = PackedInt32Array()
	v.resize(2 * budget + 3)

	var trace:Array[PackedInt32Array] = []

	for d in budget + 1:
		trace.append(v.duplicate())
		for k in range(-d, d + 1, 2):
			var x:int
			if k == -d or (k != d and v[offset + k - 1] < v[offset + k + 1]):
				x = v[offset + k + 1]
			else:
				x = v[offset + k - 1] + 1

			var y = x - k
			while x < n and y < m and a[x] == b[y]: # the snake: free moves along equal lines
				x += 1
				y += 1

			v[offset + k] = x

			if x >= n and y >= m:
				return _backtrack(trace, a, b, d, offset)

	return PackedByteArray()


static func _intern(lines:PackedStringArray, ids:Dictionary) -> PackedInt32Array:
	var out = PackedInt32Array()
	out.resize(lines.size())
	for i in lines.size():
		var line = lines[i]
		var id = ids.get(line, -1)
		if id == -1:
			id = ids.size()
			ids[line] = id
		out[i] = id
	return out


static func _backtrack(trace:Array[PackedInt32Array], a:PackedInt32Array, b:PackedInt32Array,
		d_final:int, offset:int) -> PackedByteArray:
	var ops = PackedByteArray()
	var x = a.size()
	var y = b.size()

	for d in range(d_final, -1, -1):
		var v = trace[d]
		var k = x - y

		var prev_k:int
		if k == -d or (k != d and v[offset + k - 1] < v[offset + k + 1]):
			prev_k = k + 1
		else:
			prev_k = k - 1

		var prev_x = v[offset + prev_k]
		var prev_y = prev_x - prev_k

		while x > prev_x and y > prev_y: # unwind the snake
			ops.append(_Op.EQUAL)
			x -= 1
			y -= 1

		if d > 0:
			ops.append(_Op.INSERT if prev_k == k + 1 else _Op.DELETE)

		x = prev_x
		y = prev_y

	ops.reverse()
	return ops


static func _build_hunks(ops:PackedByteArray, old_lines:PackedStringArray,
		new_lines:PackedStringArray, context:int) -> Array[Dictionary]:
	var hunks:Array[Dictionary] = []
	var n_ops = ops.size()

	var old_at = PackedInt32Array()
	var new_at = PackedInt32Array()
	old_at.resize(n_ops + 1)
	new_at.resize(n_ops + 1)
	var oi = 0
	var ni = 0
	for i in n_ops:
		old_at[i] = oi
		new_at[i] = ni
		if ops[i] != _Op.INSERT:
			oi += 1
		if ops[i] != _Op.DELETE:
			ni += 1
	old_at[n_ops] = oi
	new_at[n_ops] = ni

	var i = 0
	while i < n_ops:
		if ops[i] == _Op.EQUAL:
			i += 1
			continue

		var first = i
		var last = i
		var j = i
		while j < n_ops:
			if ops[j] != _Op.EQUAL:
				last = j
				j += 1
				continue
			var run = j
			while j < n_ops and ops[j] == _Op.EQUAL:
				j += 1
			if j >= n_ops or j - run > 2 * context:
				break

		hunks.append(_make_hunk(ops, old_lines, new_lines,
			maxi(0, first - context), mini(n_ops - 1, last + context), old_at, new_at))
		i = last + 1

	return hunks


static func _make_hunk(ops:PackedByteArray, old_lines:PackedStringArray,
		new_lines:PackedStringArray, start:int, end:int, old_at:PackedInt32Array,
		new_at:PackedInt32Array) -> Dictionary:
	var lines = []
	var i = start
	while i <= end:
		if ops[i] == _Op.EQUAL:
			lines.append({GitUtil.Keys.ORIGIN: " ", GitUtil.Keys.TEXT: old_lines[old_at[i]]})
			i += 1
			continue

		var dels = []
		var adds = []
		while i <= end and ops[i] != _Op.EQUAL:
			if ops[i] == _Op.DELETE:
				dels.append({GitUtil.Keys.ORIGIN: "-", GitUtil.Keys.TEXT: old_lines[old_at[i]]})
			else:
				adds.append({GitUtil.Keys.ORIGIN: "+", GitUtil.Keys.TEXT: new_lines[new_at[i]]})
			i += 1
		lines.append_array(dels)
		lines.append_array(adds)

	var old_count = old_at[end + 1] - old_at[start]
	var new_count = new_at[end + 1] - new_at[start]

	return {
		GitUtil.Keys.OLD_START: old_at[start] if old_count == 0 else old_at[start] + 1,
		GitUtil.Keys.OLD_COUNT: old_count,
		GitUtil.Keys.NEW_START: new_at[start] if new_count == 0 else new_at[start] + 1,
		GitUtil.Keys.NEW_COUNT: new_count,
		GitUtil.Keys.HEADING: "", # git guesses the enclosing function; we do not, and it is optional
		GitUtil.Keys.NO_NEWLINE: false, # see diff_lines()
		GitUtil.Keys.LINES: lines,
	}


enum Marker {
	ADDED         = 1 << 0,
	MODIFIED      = 1 << 1,
	DELETED_ABOVE = 1 << 2,
	DELETED_BELOW = 1 << 3,
	NO_BASELINE   = 1 << 4,
}


static func fill_markers(line_count:int, mask:int) -> PackedByteArray:
	var markers = PackedByteArray()
	if line_count <= 0:
		return markers
	markers.resize(line_count)
	markers.fill(mask)
	return markers


static func hunks_to_markers(hunks:Array, line_count:int) -> PackedByteArray:
	var markers = PackedByteArray()
	if line_count <= 0:
		return markers
	markers.resize(line_count)
	markers.fill(0)

	for hunk:Dictionary in hunks:
		var new_i:int = hunk[GitUtil.Keys.NEW_START]
		if hunk[GitUtil.Keys.NEW_COUNT] != 0:
			new_i -= 1

		var lines:Array = hunk[GitUtil.Keys.LINES]
		var i = 0
		while i < lines.size():
			if lines[i][GitUtil.Keys.ORIGIN] == " ":
				new_i += 1
				i += 1
				continue

			var adds = 0
			var dels = 0
			var block = new_i # the first added line, or the line the removal sits in front of
			while i < lines.size() and lines[i][GitUtil.Keys.ORIGIN] != " ":
				if lines[i][GitUtil.Keys.ORIGIN] == "+":
					adds += 1
				else:
					dels += 1
				i += 1
			new_i += adds

			if adds > 0:
				var mask = Marker.MODIFIED if dels > 0 else Marker.ADDED
				for line in range(block, block + adds):
					_mark(markers, line, mask)
			elif dels > 0:
				if block < line_count:
					_mark(markers, block, Marker.DELETED_ABOVE)
				else:
					_mark(markers, line_count - 1, Marker.DELETED_BELOW)

	return markers


static func _mark(markers:PackedByteArray, line:int, mask:int) -> void:
	if line < 0 or line >= markers.size():
		return
	markers[line] |= mask


static func map_new_to_old(hunks:Array, line:int) -> int:
	if line < 0:
		return -1

	var offset = 0

	for hunk:Dictionary in hunks:
		var new_start:int = hunk[GitUtil.Keys.NEW_START]
		if hunk[GitUtil.Keys.NEW_COUNT] != 0:
			new_start -= 1

		if line < new_start:
			continue

		if line < new_start + hunk[GitUtil.Keys.NEW_COUNT]:
			return _map_within(hunk, line, new_start)

		offset += hunk[GitUtil.Keys.OLD_COUNT] - hunk[GitUtil.Keys.NEW_COUNT]

	return line + offset


static func _map_within(hunk:Dictionary, line:int, new_start:int) -> int:
	var old_i:int = hunk[GitUtil.Keys.OLD_START]
	if hunk[GitUtil.Keys.OLD_COUNT] != 0:
		old_i -= 1
	var new_i = new_start

	for entry:Dictionary in hunk[GitUtil.Keys.LINES]:
		match entry[GitUtil.Keys.ORIGIN]:
			"-":
				old_i += 1 # occupies no new line, so `line` cannot be it
			"+":
				if new_i == line:
					return -1
				new_i += 1
			_:
				if new_i == line:
					return old_i
				old_i += 1
				new_i += 1

	return -1 # unreachable while the caller only enters for a line the hunk covers
