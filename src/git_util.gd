## static helpers for git discovery, status, history, and patches.

const UFile = preload("uid://bl33psa06nv1e") #! resolve ALibRuntime.Utils.UFile.Methods

const GitColors = GitService.GitColors

const MAX_DEPTH = 5

const LOG_LIMIT = 100

const LOG_FIELDS:PackedStringArray = ["%h", "%s", "%an", "%ar", "%H", "%D"]

const TAG_PREFIX = "tag: "

const SHORT_OID = 7

const LOG_SEP = "\u001f"

const PRUNE_DIRS:PackedStringArray = [".git", ".godot", ".import", "node_modules"]

enum Kind {
	ORDINARY,
	RENAMED,
	UNMERGED,
	UNTRACKED,
	IGNORED,
}

enum Status {
	NONE,
	MODIFIED,
	ADDED,
	DELETED,
	RENAMED,
	COPIED,
	TYPE_CHANGED,
	UNMERGED,
}

const CHAR_STATUS = {
	".": Status.NONE,
	"M": Status.MODIFIED,
	"A": Status.ADDED,
	"D": Status.DELETED,
	"R": Status.RENAMED,
	"C": Status.COPIED,
	"T": Status.TYPE_CHANGED,
	"U": Status.UNMERGED,
}

const STATUS_LABELS = {
	Status.MODIFIED: "Modified",
	Status.ADDED: "Added",
	Status.DELETED: "Deleted",
	Status.RENAMED: "Renamed",
	Status.COPIED: "Copied",
	Status.TYPE_CHANGED: "Type Change",
	Status.UNMERGED: "Conflict",
}

const STATUS_LETTERS = {
	Status.MODIFIED: "M",
	Status.ADDED: "A",
	Status.DELETED: "D",
	Status.RENAMED: "R",
	Status.COPIED: "C",
	Status.TYPE_CHANGED: "T",
	Status.UNMERGED: "U",
}


static func get_status_label(file_data:Dictionary) -> String:
	return _status_display(file_data, STATUS_LABELS, "Untracked", "Conflict", "Unknown")


static func get_status_letter(file_data:Dictionary) -> String:
	return _status_display(file_data, STATUS_LETTERS, "?", "U", "")


enum Severity {
	NONE,
	NESTED,
	IGNORED,
	STAGED,
	UNTRACKED,
	MODIFIED,
	DELETED,
	CONFLICTED,
}

static func get_status_severity(file_data:Dictionary) -> int:
	match file_data.get(Keys.KIND, Kind.ORDINARY):
		Kind.UNMERGED: return Severity.CONFLICTED
		Kind.UNTRACKED: return Severity.UNTRACKED

	var staged = file_data.get(Keys.STAGED, false)
	var unstaged = file_data.get(Keys.UNSTAGED, false)
	if staged and not unstaged:
		return Severity.STAGED

	if file_data.get(Keys.WORKTREE, Status.NONE) == Status.MODIFIED:
		return Severity.MODIFIED
	if file_data.get(Keys.WORKTREE, Status.NONE) == Status.DELETED:
		return Severity.DELETED
	return Severity.IGNORED


static func get_status_color(file_data:Dictionary, colors:GitColors) -> Color:
	match get_status_severity(file_data):
		Severity.CONFLICTED: return colors.conflicted
		Severity.DELETED: return colors.conflicted
		Severity.MODIFIED: return colors.modified
		Severity.UNTRACKED: return colors.untracked
		Severity.STAGED: return colors.staged
	return colors.ignored


static func ignored_covers(entry:String, path:String) -> bool:
	if entry.ends_with("/"):
		return path.begins_with(entry)
	return path == entry


static func is_path_ignored(ignored:Array, path:String) -> bool:
	for entry:String in ignored:
		if ignored_covers(entry, path):
			return true
	return false


static func get_letter_set() -> String:
	return "".join(STATUS_LETTERS.values()) + "?"


static func count_changes(status:Dictionary) -> Dictionary:
	var counts = {
		Keys.COUNT_STAGED: 0,
		Keys.COUNT_UNSTAGED: 0,
		Keys.COUNT_UNTRACKED: 0,
		Keys.COUNT_CONFLICTED: 0,
		Keys.COUNT_TOTAL: 0,
	}

	var files:Dictionary = status.get(Keys.FILES, {})
	counts[Keys.COUNT_TOTAL] = files.size()

	for file_data:Dictionary in files.values():
		match file_data.get(Keys.KIND, Kind.ORDINARY):
			Kind.UNTRACKED:
				counts[Keys.COUNT_UNTRACKED] += 1
				continue
			Kind.UNMERGED:
				counts[Keys.COUNT_CONFLICTED] += 1
				continue

		if file_data.get(Keys.STAGED, false):
			counts[Keys.COUNT_STAGED] += 1
		if file_data.get(Keys.UNSTAGED, false):
			counts[Keys.COUNT_UNSTAGED] += 1

	return counts


static func get_branch_label(branch:Dictionary) -> String:
	if branch.get(Keys.BRANCH_DETACHED, false):
		var oid:String = branch.get(Keys.BRANCH_OID, "")
		return "%s (detached)" % oid.substr(0, SHORT_OID) if not oid.is_empty() else "(detached)"

	var name:String = branch.get(Keys.BRANCH_NAME, "")
	if name.is_empty():
		return "" # not a repo, or git is not on PATH — say nothing rather than guess

	if branch.get(Keys.BRANCH_INITIAL, false):
		return "%s (no commits)" % name

	var upstream:String = branch.get(Keys.BRANCH_UPSTREAM, "")
	if upstream.is_empty():
		return name

	return "%s → %s" % [name, upstream]


static func get_divergence_label(branch:Dictionary) -> String:
	var parts:Array[String] = []
	var ahead:int = branch.get(Keys.BRANCH_AHEAD, 0)
	var behind:int = branch.get(Keys.BRANCH_BEHIND, 0)

	if ahead > 0:
		parts.append("↑%d" % ahead)
	if behind > 0:
		parts.append("↓%d" % behind)

	return " ".join(parts)


static func get_repo_info(status:Dictionary, commits:Array) -> Dictionary:
	return {
		Keys.REPO: status.get(Keys.REPO, ""),
		Keys.BRANCH: status.get(Keys.BRANCH, _new_branch()),
		Keys.COUNTS: count_changes(status),
		Keys.LAST_COMMIT: commits[0] if not commits.is_empty() else {},
	}


static func format_repo_tooltip(info:Dictionary) -> String:
	var blocks:Array[String] = []

	var repo:String = info.get(Keys.REPO, "")
	if not repo.is_empty():
		blocks.append(repo)

	var branch:Dictionary = info.get(Keys.BRANCH, {})
	var branch_lines:Array[String] = []
	var label = get_branch_label(branch)
	if not label.is_empty():
		branch_lines.append(label)

	var ahead:int = branch.get(Keys.BRANCH_AHEAD, 0)
	var behind:int = branch.get(Keys.BRANCH_BEHIND, 0)
	if ahead > 0 or behind > 0:
		var drift:Array[String] = []
		if ahead > 0:
			drift.append("↑%d ahead" % ahead)
		if behind > 0:
			drift.append("↓%d behind" % behind)
		branch_lines.append(" · ".join(drift))

	if not branch_lines.is_empty():
		blocks.append("\n".join(branch_lines))

	blocks.append(_format_counts(info.get(Keys.COUNTS, {})))

	var commit:Dictionary = info.get(Keys.LAST_COMMIT, {})
	if not commit.is_empty():
		blocks.append("%s  %s\n%s · %s" % [
			commit.get(Keys.HASH, ""),
			commit.get(Keys.SUBJECT, ""),
			commit.get(Keys.AUTHOR, ""),
			commit.get(Keys.DATE, ""),
		])

	return "\n\n".join(blocks)


static func _format_counts(counts:Dictionary) -> String:
	var total:int = counts.get(Keys.COUNT_TOTAL, 0)
	if total == 0:
		return "Clean"

	var parts:Array[String] = []
	for key in [Keys.COUNT_STAGED, Keys.COUNT_UNSTAGED, Keys.COUNT_UNTRACKED, Keys.COUNT_CONFLICTED]:
		var n:int = counts.get(key, 0)
		if n > 0:
			parts.append("%d %s" % [n, key])

	return "%d changed — %s" % [total, ", ".join(parts)]


static func _status_display(file_data:Dictionary, table:Dictionary, untracked:String, conflict:String, unknown:String) -> String:
	match file_data.get(Keys.KIND, Kind.ORDINARY):
		Kind.UNTRACKED:
			return untracked
		Kind.UNMERGED:
			return conflict

	var worktree:Status = file_data.get(Keys.WORKTREE, Status.NONE)
	var index:Status = file_data.get(Keys.INDEX, Status.NONE)
	return table.get(worktree if worktree != Status.NONE else index, unknown)

const EXEC_FAILED = -1

const PATCH_TMP_DIR = "user://git_service"

static var _warned_no_git:bool = false

#! keys exit:int output:Array
static func run_git(repo_dir:String, args:Array, read_stderr:=false) -> Dictionary:
	var final_args:Array = ["-C", ProjectSettings.globalize_path(repo_dir)]
	final_args.append_array(args)

	var output = []
	var exit_code = OS.execute("git", final_args, output, read_stderr)
	if exit_code == EXEC_FAILED and not _warned_no_git:
		_warned_no_git = true # racy across worker threads, but the worst case is a repeated error
		push_error("GitService: could not run `git` — is it installed and on PATH?")
	return {
		Keys.EXIT: exit_code,
		Keys.OUTPUT: output,
	}


## Runs a diff and reads its output back off disk instead of the pipe. Windows decodes child
## output with the ANSI code page, which mangles every non-ASCII byte git writes; `--output=`
## hands us a file, and FileAccess reads that as the UTF-8 it actually is.
#! keys exit:int text:String
static func run_git_to_file(repo_dir:String, args:Array, tag:String) -> Dictionary:
	var tmp_path = PATCH_TMP_DIR.path_join("%d_%s.patch" % [OS.get_thread_caller_id(), tag])
	DirAccess.make_dir_recursive_absolute(PATCH_TMP_DIR)

	var final_args = args.duplicate()
	final_args.insert(1, "--output=" + ProjectSettings.globalize_path(tmp_path)) # before any `--`

	var result = run_git(repo_dir, final_args)

	var text = FileAccess.get_file_as_string(tmp_path) if FileAccess.file_exists(tmp_path) else ""
	DirAccess.remove_absolute(tmp_path)

	return {
		Keys.EXIT: result[Keys.EXIT],
		Keys.TEXT: text,
	}


static func to_lines(text:String) -> PackedStringArray:
	return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


## Rebuilds a patch's pre-image from its post-image, so the HEAD copy of a file can be recovered
## without ever asking git to stream blob bytes back through the pipe.
static func reverse_apply(new_lines:PackedStringArray, hunks:Array) -> PackedStringArray:
	var out := PackedStringArray()
	var cursor = 0

	for hunk:Dictionary in hunks:
		var new_count:int = hunk[Keys.NEW_COUNT]
		var start:int = hunk[Keys.NEW_START]
		if new_count != 0:
			start -= 1 # 1-based over the lines it covers; already the gap index when it covers none

		for i in range(cursor, mini(start, new_lines.size())):
			out.append(new_lines[i])

		for entry:Dictionary in hunk[Keys.LINES]:
			if entry[Keys.ORIGIN] != "+":
				out.append(entry[Keys.TEXT])

		cursor = maxi(cursor, start + new_count)

	for i in range(mini(cursor, new_lines.size()), new_lines.size()):
		out.append(new_lines[i])

	return out


static func is_repo(dir_path:String) -> bool:
	var git_path = dir_path.path_join(".git")
	return DirAccess.dir_exists_absolute(git_path) or FileAccess.file_exists(git_path)


static func find_repos(root:="res://", max_depth:=MAX_DEPTH) -> Array[String]:
	var repos:Array[String] = []
	var queue = [[UFile.ensure_dir_slash(root), 0]]

	while not queue.is_empty():
		var entry = queue.pop_front()
		var dir_path:String = entry[0]
		var depth:int = entry[1]

		if is_repo(dir_path):
			repos.append(dir_path)

		if depth >= max_depth:
			continue

		var contents = UFile.get_dir_contents(dir_path, true, true)
		for sub_dir:String in contents.get("dirs", []):
			if sub_dir.trim_suffix("/").get_file() in PRUNE_DIRS:
				continue
			queue.append([sub_dir, depth + 1])

	return repos


static func find_repo_for(path:String, repos:Array) -> String:
	var best = ""
	for repo:String in repos:
		if path.begins_with(repo) and repo.length() > best.length():
			best = repo
	return best


static func get_status(repo_dir:String) -> Dictionary:
	# quotepath stays on (git's default) so non-ASCII paths arrive as ASCII \nnn escapes that
	# _unquote_path decodes itself — Windows would otherwise mis-decode the raw UTF-8 bytes
	var result = run_git(repo_dir, [
		"status", "--porcelain=v2", "--branch", "--untracked-files=all",
		"--ignored=matching",
	])

	var output:Array = result[Keys.OUTPUT]
	if result[Keys.EXIT] != 0 or output.is_empty():
		return parse_status("", repo_dir)

	return parse_status(String(output[0]), repo_dir)


static func parse_status(text:String, repo_dir:String) -> Dictionary:
	var status = {
		Keys.REPO: repo_dir,
		Keys.BRANCH: _new_branch(),
		Keys.FILES: {},
		Keys.IGNORED: [] as Array[String],
	}

	for raw_line in text.split("\n", false):
		var line = raw_line.trim_suffix("\r")
		if line.begins_with("# branch."):
			_parse_branch_header(line, status[Keys.BRANCH])
		elif not line.begins_with("#"): # ignore headers we don't recognise, as git asks
			_parse_entry(line, repo_dir, status[Keys.FILES], status[Keys.IGNORED])

	return status


static func attach_diffs(repo_dir:String, status:Dictionary) -> void:
	var files:Dictionary = status.get(Keys.FILES, {})
	if files.is_empty():
		return

	_merge_patch(repo_dir, files, [], Keys.HUNKS_UNSTAGED)      # worktree vs index
	_merge_patch(repo_dir, files, ["--cached"], Keys.HUNKS_STAGED) # index vs HEAD


const DIFF_ARGS:Array = ["--patch", "--no-ext-diff", "--no-color", "--no-textconv"]

static func _merge_patch(repo_dir:String, files:Dictionary, extra_args:Array, hunks_key:StringName) -> void:
	var args = ["diff"]
	args.append_array(DIFF_ARGS)
	args.append_array(extra_args)

	var result = run_git_to_file(repo_dir, args, hunks_key)
	if result[Keys.EXIT] != 0:
		return

	var text:String = result[Keys.TEXT]
	if text.is_empty():
		return

	var patch = parse_patch(text, repo_dir)
	for res_path:String in patch:
		if not files.has(res_path):
			continue # a path in the diff but not in the status: nothing to hang it off
		var parsed:Dictionary = patch[res_path]
		files[res_path][hunks_key] = parsed[Keys.HUNKS]
		if parsed[Keys.BINARY]:
			files[res_path][Keys.BINARY] = true


const REV_HEAD = "HEAD"

enum Head {
	OK,
	ABSENT,
	ERROR,
	IGNORED,
}

static func build_exists_args(rev:String, repo_dir:String, res_path:String) -> Array:
	return ["cat-file", "-e", "%s:%s" % [rev, to_repo_path(repo_dir, res_path)]]


static func build_check_ignore_args(repo_dir:String, res_path:String) -> Array:
	return ["check-ignore", "-q", "--", to_repo_path(repo_dir, res_path)]


static func is_ignored(repo_dir:String, res_path:String) -> bool:
	return run_git(repo_dir, build_check_ignore_args(repo_dir, res_path))[Keys.EXIT] == 0


## `git show <rev>:<path>` streams blob bytes straight to stdout and ignores `--output`, so it
## cannot be read back safely. The file on disk is the diff's post-image and FileAccess decodes it
## correctly everywhere, so reverse-applying `git diff HEAD` to it recovers the HEAD copy instead.
#! keys head:Head text:String
static func get_file_at_head(repo_dir:String, res_path:String) -> Dictionary:
	if run_git(repo_dir, build_exists_args(REV_HEAD, repo_dir, res_path))[Keys.EXIT] != 0:
		if run_git(repo_dir, ["rev-parse", "--git-dir"])[Keys.EXIT] != 0:
			return {Keys.HEAD: Head.ERROR, Keys.TEXT: ""}
		var head:Head = Head.IGNORED if is_ignored(repo_dir, res_path) else Head.ABSENT
		return {Keys.HEAD: head, Keys.TEXT: ""}

	var args:Array = ["diff", REV_HEAD]
	args.append_array(DIFF_ARGS)
	args.append_array(["--", to_pathspec(repo_dir, res_path)])

	var result = run_git_to_file(repo_dir, args, "baseline")
	if result[Keys.EXIT] != 0:
		return {Keys.HEAD: Head.ERROR, Keys.TEXT: ""}

	var file_data:Dictionary = parse_patch(result[Keys.TEXT], repo_dir).get(res_path, {})
	if file_data.get(Keys.BINARY, false):
		return {Keys.HEAD: Head.ERROR, Keys.TEXT: ""}

	var disk_lines = to_lines(FileAccess.get_file_as_string(res_path))
	var head_lines = reverse_apply(disk_lines, file_data.get(Keys.HUNKS, []))
	return {Keys.HEAD: Head.OK, Keys.TEXT: "\n".join(head_lines)}


static func get_log(repo_dir:String, limit:=LOG_LIMIT) -> Array[Dictionary]:
	var result = run_git(repo_dir, [
		"log",
		"--max-count=%s" % limit,
		"--pretty=format:" + LOG_SEP.join(LOG_FIELDS),
	])

	var output:Array = result[Keys.OUTPUT]
	if result[Keys.EXIT] != 0 or output.is_empty():
		return [] as Array[Dictionary]

	return parse_log(String(output[0]))


static func parse_log(text:String) -> Array[Dictionary]:
	var commits:Array[Dictionary] = []

	for raw_line in text.split("\n", false):
		var line = raw_line.trim_suffix("\r")
		var parts = line.split(LOG_SEP)
		if parts.size() < LOG_FIELDS.size():
			continue

		commits.append({
			Keys.HASH: parts[0],
			Keys.SUBJECT: parts[1],
			Keys.AUTHOR: parts[2],
			Keys.DATE: parts[3],
			Keys.FULL_HASH: parts[4],
			Keys.TAGS: _parse_refs(parts[5]),
		})

	return commits


static func _parse_refs(field:String) -> Array[String]:
	var tags:Array[String] = []
	for ref in field.split(",", false):
		var name = ref.strip_edges()
		if name.begins_with(TAG_PREFIX):
			tags.append(name.substr(TAG_PREFIX.length()))
	return tags


static func build_blame_args(rev:String, repo_dir:String, res_path:String) -> Array:
	return ["blame", "--porcelain", rev, "--", to_repo_path(repo_dir, res_path)]


#! keys head:Head commits:Dictionary blame_lines:PackedStringArray
static func get_blame(repo_dir:String, res_path:String, rev:=REV_HEAD) -> Dictionary:
	var result = run_git(repo_dir, build_blame_args(rev, repo_dir, res_path))

	var output:Array = result[Keys.OUTPUT]
	if result[Keys.EXIT] != 0 or output.is_empty():
		return {Keys.HEAD: Head.ABSENT, Keys.COMMITS: {}, Keys.BLAME_LINES: PackedStringArray()}

	var parsed = parse_blame(String(output[0]))
	parsed[Keys.HEAD] = Head.OK
	return parsed


#! keys commits:Dictionary blame_lines:PackedStringArray
static func parse_blame(text:String) -> Dictionary:
	var commits:Dictionary = {}
	var blame_lines := PackedStringArray()
	var sha := ""

	for raw_line in text.split("\n", false):
		var line = raw_line.trim_suffix("\r")

		if line.begins_with("\t"):
			sha = ""
			continue

		if not sha.is_empty():
			_parse_blame_header(line, commits[sha])
			continue

		var header = line.split(" ", false)
		if header.size() < 3:
			continue

		sha = header[0]
		var final_line = int(header[2])
		if final_line > blame_lines.size():
			blame_lines.resize(final_line)
		blame_lines[final_line - 1] = sha

		if not commits.has(sha):
			commits[sha] = _new_blame_commit(sha)

	return {Keys.COMMITS: commits, Keys.BLAME_LINES: blame_lines}


static func _parse_blame_header(line:String, commit:Dictionary) -> void:
	var parts = line.split(" ", true, 1)
	if parts.size() < 2:
		return # `boundary` and friends carry no value

	var value = parts[1]
	match parts[0]:
		"author": commit[Keys.AUTHOR] = value
		"author-mail": commit[Keys.AUTHOR_MAIL] = value.trim_prefix("<").trim_suffix(">")
		"author-time":
			commit[Keys.AUTHOR_TIME] = int(value)
			commit[Keys.DATE] = format_relative_time(int(value))
		"author-tz": commit[Keys.AUTHOR_TZ] = value
		"summary": commit[Keys.SUBJECT] = value


static func _new_blame_commit(sha:String) -> Dictionary:
	return {
		Keys.HASH: sha.left(SHORT_OID),
		Keys.FULL_HASH: sha,
		Keys.SUBJECT: "",
		Keys.AUTHOR: "",
		Keys.DATE: "",
		Keys.TAGS: [] as Array[String],
		Keys.AUTHOR_MAIL: "",
		Keys.AUTHOR_TIME: 0,
		Keys.AUTHOR_TZ: "",
	}


const MINUTE = 60
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR
const WEEK = 7 * DAY
const MONTH = 30 * DAY
const YEAR = 365 * DAY

const RELATIVE_UNITS = [
	[1, 90, "second"],
	[MINUTE, 90 * MINUTE, "minute"],
	[HOUR, 36 * HOUR, "hour"],
	[DAY, 14 * DAY, "day"],
	[WEEK, 10 * WEEK, "week"],
	[MONTH, 12 * MONTH, "month"],
]

static func format_relative_time(unix_time:int, now:=-1) -> String:
	if unix_time <= 0:
		return ""
	if now < 0:
		now = int(Time.get_unix_time_from_system())

	var delta = now - unix_time
	if delta < 0:
		return "in the future"

	for unit in RELATIVE_UNITS:
		if delta < unit[1]:
			return _plural(int(round(float(delta) / unit[0])), unit[2])

	return _plural(int(round(float(delta) / YEAR)), "year")


static func _plural(count:int, unit:String) -> String:
	return "%d %s%s ago" % [count, unit, "" if count == 1 else "s"]


static func _new_branch() -> Dictionary:
	return {
		Keys.BRANCH_NAME: "",
		Keys.BRANCH_OID: "",
		Keys.BRANCH_UPSTREAM: "",
		Keys.BRANCH_AHEAD: 0,
		Keys.BRANCH_BEHIND: 0,
		Keys.BRANCH_DETACHED: false,
		Keys.BRANCH_INITIAL: false,
	}


static func _parse_branch_header(line:String, branch:Dictionary) -> void:
	var parts = line.split(" ", true, 2)
	if parts.size() < 3:
		return

	match parts[1]:
		"branch.oid":
			branch[Keys.BRANCH_INITIAL] = parts[2] == "(initial)"
			if not branch[Keys.BRANCH_INITIAL]:
				branch[Keys.BRANCH_OID] = parts[2]
		"branch.head":
			if parts[2] == "(detached)":
				branch[Keys.BRANCH_DETACHED] = true
			else:
				branch[Keys.BRANCH_NAME] = parts[2]
		"branch.upstream":
			branch[Keys.BRANCH_UPSTREAM] = parts[2]
		"branch.ab":
			for field in parts[2].split(" ", false):
				if field.begins_with("+"):
					branch[Keys.BRANCH_AHEAD] = field.substr(1).to_int()
				elif field.begins_with("-"):
					branch[Keys.BRANCH_BEHIND] = field.substr(1).to_int()


static func _parse_entry(line:String, repo_dir:String, files:Dictionary, ignored:Array) -> void:
	match line.substr(0, 2):
		"1 ":
			var parts = line.split(" ", true, 8)
			if parts.size() < 9:
				return
			var entry = _new_entry(Kind.ORDINARY, parts[1])
			entry[Keys.SUB] = parts[2]
			entry[Keys.OID_HEAD] = parts[6]
			entry[Keys.OID_INDEX] = parts[7]
			files[_to_res_path(repo_dir, parts[8])] = entry

		"2 ": 
			var parts = line.split(" ", true, 9)
			if parts.size() < 10:
				return
			var paths = parts[9].split("\t")
			if paths.size() < 2:
				return
			var entry = _new_entry(Kind.RENAMED, parts[1])
			entry[Keys.SUB] = parts[2]
			entry[Keys.OID_HEAD] = parts[6]
			entry[Keys.OID_INDEX] = parts[7]
			entry[Keys.SCORE] = parts[8].substr(1).to_int() # drop the leading R / C
			entry[Keys.RENAMED_FROM] = _to_res_path(repo_dir, paths[1])
			files[_to_res_path(repo_dir, paths[0])] = entry

		"u ":
			var parts = line.split(" ", true, 10)
			if parts.size() < 11:
				return
			var entry = _new_entry(Kind.UNMERGED, parts[1])
			entry[Keys.SUB] = parts[2]
			files[_to_res_path(repo_dir, parts[10])] = entry

		"? ":
			files[_to_res_path(repo_dir, line.substr(2))] = _new_entry(Kind.UNTRACKED, "..")

		"! ":
			ignored.append(_to_res_path(repo_dir, line.substr(2)))


static func _new_entry(kind:Kind, xy:String) -> Dictionary:
	var index:Status = CHAR_STATUS.get(xy.substr(0, 1), Status.NONE)
	var worktree:Status = CHAR_STATUS.get(xy.substr(1, 1), Status.NONE)

	return {
		Keys.KIND: kind,
		Keys.INDEX: index,
		Keys.WORKTREE: worktree,
		Keys.STAGED: index != Status.NONE,
		Keys.UNSTAGED: worktree != Status.NONE,
		Keys.RENAMED_FROM: "",
		Keys.SCORE: 0,
		Keys.SUB: "",
		Keys.OID_HEAD: "",
		Keys.OID_INDEX: "",
		Keys.BINARY: false,
		Keys.HUNKS_STAGED: [],
		Keys.HUNKS_UNSTAGED: [],
	}


static func parse_patch(text:String, repo_dir:String) -> Dictionary:
	var out = {}

	var res_path = ""
	var header = "" # the "a/x b/x" tail of the current `diff --git` line, kept for the binary case
	var file_data = {}
	var hunk = {}

	for raw_line in text.trim_suffix("\n").split("\n"):
		var line = raw_line.trim_suffix("\r")

		if line.begins_with("diff --git "):
			res_path = ""
			header = line.substr(11)
			file_data = {Keys.HUNKS: [], Keys.BINARY: false}
			hunk = {}
			continue

		if file_data.is_empty():
			continue

		if line.begins_with("+++ ") and line != "+++ /dev/null":
			res_path = _patch_path(repo_dir, line.substr(4), "b/")
			out[res_path] = file_data
			continue
		if line.begins_with("--- ") and line != "--- /dev/null" and res_path.is_empty():
			res_path = _patch_path(repo_dir, line.substr(4), "a/")
			out[res_path] = file_data
			continue

		if line.begins_with("Binary files ") or line.begins_with("GIT binary patch"):
			file_data[Keys.BINARY] = true
			if res_path.is_empty():
				res_path = _header_path(repo_dir, header)
				if not res_path.is_empty():
					out[res_path] = file_data
			continue

		if line.begins_with("@@"):
			hunk = _parse_hunk_header(line)
			file_data[Keys.HUNKS].append(hunk)
			continue

		if hunk.is_empty():
			continue # still in the file header (index / mode / rename lines)

		var origin = line.substr(0, 1)
		match origin:
			" ", "+", "-":
				hunk[Keys.LINES].append({
					Keys.ORIGIN: origin,
					Keys.TEXT: line.substr(1),
				})
			"":
				hunk[Keys.LINES].append({Keys.ORIGIN: " ", Keys.TEXT: ""})
			"\\":
				hunk[Keys.NO_NEWLINE] = true

	return out


static func _parse_hunk_header(line:String) -> Dictionary:
	var hunk = {
		Keys.OLD_START: 0,
		Keys.OLD_COUNT: 0,
		Keys.NEW_START: 0,
		Keys.NEW_COUNT: 0,
		Keys.HEADING: "",
		Keys.NO_NEWLINE: false,
		Keys.LINES: [],
	}

	var close = line.find("@@", 2)
	if close < 0:
		return hunk

	hunk[Keys.HEADING] = line.substr(close + 2).strip_edges()

	for field in line.substr(2, close - 2).strip_edges().split(" ", false):
		var side = field.substr(0, 1)
		if side != "-" and side != "+":
			continue

		var nums = field.substr(1).split(",")
		var start = nums[0].to_int()
		var count = nums[1].to_int() if nums.size() > 1 else 1

		if side == "-":
			hunk[Keys.OLD_START] = start
			hunk[Keys.OLD_COUNT] = count
		else:
			hunk[Keys.NEW_START] = start
			hunk[Keys.NEW_COUNT] = count

	return hunk


static func _patch_path(repo_dir:String, field:String, prefix:String) -> String:
	return repo_dir.path_join(_unquote_path(field.trim_suffix("\t")).trim_prefix(prefix))


static func _header_path(repo_dir:String, header:String) -> String:
	if header.begins_with("\""):
		var close = _find_closing_quote(header)
		if close < 0:
			return ""
		return repo_dir.path_join(_unquote_path(header.substr(0, close + 1)).trim_prefix("a/"))

	if header.length() < 7 or (header.length() - 5) % 2 != 0:
		return ""

	@warning_ignore("integer_division")
	var path = header.substr(2, (header.length() - 5) / 2)
	if header != "a/%s b/%s" % [path, path]:
		return "" # a rename, or something else we cannot read back confidently
	return repo_dir.path_join(path)


static func _find_closing_quote(text:String) -> int:
	var i = 1
	while i < text.length():
		match text[i]:
			"\\": i += 2
			"\"": return i
			_: i += 1
	return -1


static func _to_res_path(repo_dir:String, rel_path:String) -> String:
	return repo_dir.path_join(_unquote_path(rel_path))


## Decodes git's C-quoting into bytes rather than codepoints: an escaped non-ASCII path arrives as
## one \nnn per UTF-8 byte, so treating each as a character would mangle everything above ASCII.
static func _unquote_path(path:String) -> String:
	if not path.begins_with("\""):
		return path

	path = path.substr(1, path.length() - 2)

	var out := PackedByteArray()
	var i = 0
	while i < path.length():
		if path[i] != "\\":
			out.append_array(path[i].to_utf8_buffer())
			i += 1
			continue

		i += 1
		if i >= path.length():
			break

		var escaped = path[i]
		i += 1
		match escaped:
			"a": out.append(0x07)
			"b": out.append(0x08)
			"t": out.append(0x09)
			"n": out.append(0x0a)
			"v": out.append(0x0b)
			"f": out.append(0x0c)
			"r": out.append(0x0d)
			"\"": out.append(0x22)
			"\\": out.append(0x5c)
			_:
				if escaped >= "0" and escaped <= "7": # \nnn, an octal byte
					var code = 0
					for digit in escaped + path.substr(i, 2):
						code = code * 8 + (digit.unicode_at(0) - 48)
					i += 2
					out.append(code & 0xff)
				else:
					out.append_array(escaped.to_utf8_buffer())

	return out.get_string_from_utf8()


#region Commands

const PATHSPEC_LITERAL = ":(literal)"

enum State {
	STAGED     = 1 << 0,
	UNSTAGED   = 1 << 1,
	UNTRACKED  = 1 << 2,
	CONFLICTED = 1 << 3,
}

enum Command {
	STAGE,
	UNSTAGE,
	DISCARD,
	DELETE,
}
const COMMAND_DESTRUCTIVE = [Command.DISCARD, Command.DELETE]

const COMMANDS = {
	Command.STAGE: {
		Keys.CMD_LABEL: "Stage",
		Keys.CMD_ARGS: ["add"],
		Keys.CMD_ACCEPTS: State.UNSTAGED | State.UNTRACKED | State.CONFLICTED,
		Keys.CMD_DESTRUCTIVE: false,
		Keys.CMD_WORKTREE: false,
	},
	Command.UNSTAGE: {
		Keys.CMD_LABEL: "Unstage",
		Keys.CMD_ARGS: ["restore", "--staged"],
		Keys.CMD_ACCEPTS: State.STAGED,
		Keys.CMD_DESTRUCTIVE: false,
		Keys.CMD_WORKTREE: false,
	},
	Command.DISCARD: {
		Keys.CMD_LABEL: "Discard Changes",
		Keys.CMD_ARGS: ["restore"],
		Keys.CMD_ACCEPTS: State.UNSTAGED,
		Keys.CMD_DESTRUCTIVE: true,
		Keys.CMD_WORKTREE: true,
	},
	Command.DELETE: {
		Keys.CMD_LABEL: "Delete File",
		Keys.CMD_ARGS: ["clean", "-f"],
		Keys.CMD_ACCEPTS: State.UNTRACKED,
		Keys.CMD_DESTRUCTIVE: true,
		Keys.CMD_WORKTREE: true,
	},
}

const ARGS_UNSTAGE_INITIAL:Array = ["rm", "--cached"]


static func get_file_state(file_data:Dictionary) -> int:
	match file_data.get(Keys.KIND, Kind.ORDINARY):
		Kind.UNTRACKED:
			return State.UNTRACKED
		Kind.UNMERGED:
			return State.CONFLICTED

	var state = 0
	if file_data.get(Keys.STAGED, false):
		state |= State.STAGED
	if file_data.get(Keys.UNSTAGED, false):
		state |= State.UNSTAGED
	return state


static func command_accepts(command:Command, file_data:Dictionary) -> bool:
	return get_file_state(file_data) & int(COMMANDS[command][Keys.CMD_ACCEPTS]) != 0


static func expand_paths(command:Command, paths:Array, files:Dictionary) -> Array:
	if command != Command.UNSTAGE:
		return paths.duplicate()

	var out:Array = []
	for path in paths:
		out.append(path)
		var file_data:Dictionary = files.get(path, {})
		if file_data.get(Keys.KIND, Kind.ORDINARY) != Kind.RENAMED:
			continue
		var from:String = file_data.get(Keys.RENAMED_FROM, "")
		if not from.is_empty() and not out.has(from):
			out.append(from)
	return out


static func to_repo_path(repo_dir:String, path:String) -> String:
	return path.trim_prefix(repo_dir)


static func to_pathspec(repo_dir:String, path:String) -> String:
	return PATHSPEC_LITERAL + to_repo_path(repo_dir, path)


static func is_commandable_path(repo_dir:String, path:String) -> bool:
	var rel = to_repo_path(repo_dir, path)
	return not (rel.is_empty() or rel == "." or rel == "/")


static func build_command_args(command:Command, repo_dir:String, paths:Array, initial:=false) -> Array:
	var pathspecs:Array = []
	for path:String in paths:
		if is_commandable_path(repo_dir, path):
			pathspecs.append(to_pathspec(repo_dir, path))
	if pathspecs.is_empty():
		return []

	var args:Array = []
	if command == Command.UNSTAGE and initial:
		args.append_array(ARGS_UNSTAGE_INITIAL)
	else:
		args.append_array(COMMANDS[command][Keys.CMD_ARGS])

	args.append("--")
	args.append_array(pathspecs)
	return args


static func run_command(repo_dir:String, command:Command, paths:Array, initial:=false) -> Dictionary:
	if paths.is_empty():
		return {Keys.EXIT: 0, Keys.OUTPUT: []}

	var args = build_command_args(command, repo_dir, paths, initial)
	if args.is_empty():
		return {Keys.EXIT: 0, Keys.OUTPUT: []}

	return run_git(repo_dir, args, true)

#endregion



class Keys:
	const EXIT = &"exit"
	const OUTPUT = &"output"

	const CMD_LABEL = &"label"
	const CMD_ARGS = &"args"
	const CMD_ACCEPTS = &"accepts"
	const CMD_DESTRUCTIVE = &"destructive"
	const CMD_WORKTREE = &"worktree_write"

	const REPO = &"repo"
	const BRANCH = &"branch"
	const FILES = &"files"
	const IGNORED = &"ignored"
	const HEAD = &"head"
	const COUNTS = &"counts"
	const LAST_COMMIT = &"last_commit"

	const BRANCH_NAME = &"name"
	const BRANCH_OID = &"oid"
	const BRANCH_UPSTREAM = &"upstream"
	const BRANCH_AHEAD = &"ahead"
	const BRANCH_BEHIND = &"behind"
	const BRANCH_DETACHED = &"detached"
	const BRANCH_INITIAL = &"initial"

	const COUNT_STAGED = &"staged"
	const COUNT_UNSTAGED = &"unstaged"
	const COUNT_UNTRACKED = &"untracked"
	const COUNT_CONFLICTED = &"conflicted"
	const COUNT_TOTAL = &"total"

	const KIND = &"kind"
	const INDEX = &"index"
	const WORKTREE = &"worktree"
	const STAGED = &"staged"
	const UNSTAGED = &"unstaged"
	const RENAMED_FROM = &"renamed_from"
	const SCORE = &"score"
	const SUB = &"sub"
	const OID_HEAD = &"oid_head"
	const OID_INDEX = &"oid_index"

	const BINARY = &"binary"
	const HUNKS = &"hunks"
	const HUNKS_STAGED = &"hunks_staged"
	const HUNKS_UNSTAGED = &"hunks_unstaged"

	const OLD_START = &"old_start"
	const OLD_COUNT = &"old_count"
	const NEW_START = &"new_start"
	const NEW_COUNT = &"new_count"
	const HEADING = &"heading"
	const NO_NEWLINE = &"no_newline"
	const LINES = &"lines"
	const ORIGIN = &"origin"
	const TEXT = &"text"

	const HASH = &"hash"
	const FULL_HASH = &"full_hash"
	const SUBJECT = &"subject"
	const AUTHOR = &"author"
	const DATE = &"date"
	const TAGS = &"tags"

	const COMMITS = &"commits"
	const BLAME_LINES = &"blame_lines"
	const AUTHOR_MAIL = &"author_mail"
	const AUTHOR_TIME = &"author_time"
	const AUTHOR_TZ = &"author_tz"


class Colors:
	const REPO = Color(0.384, 0.719, 0.705, 1.0)
	
	const L_GREEN = Color(0.57, 0.92, 0.57, 1.0)
	const GREEN = Color(0.0, 0.454, 0.0, 1.0)
	const L_YELLOW = Color(0.74, 0.69, 0.466, 1.0)
	const YELLOW = Color(0.741, 0.608, 0.0, 1.0)
	const RED = Color(0.573, 0.0, 0.0, 1.0)
	const DIM = Color(0.5, 0.5, 0.5, 0.5)
