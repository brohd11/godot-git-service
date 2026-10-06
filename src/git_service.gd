## shared background git data provider for editor consumers.
## keeps repo status cached and refreshes one repo at a time.
class_name GitService
extends "res://addons/addon_lib/singleton/singleton_ref_count.gd" #! ext Singletons.RefCount



#region SingletonAPI

const PE_STRIP_CAST_SCRIPT = preload("res://addons/addon_lib/git_service/src/git_service.gd")

static func get_singleton_name() -> String:
	return "GitService"

static func get_instance() -> PE_STRIP_CAST_SCRIPT:
	return _get_instance(PE_STRIP_CAST_SCRIPT)

static func instance_valid() -> bool:
	return _instance_valid(PE_STRIP_CAST_SCRIPT)

static func register_node(node:Node):
	return _register_node(PE_STRIP_CAST_SCRIPT, node)

static func unregister_node(node:Node):
	_unregister_node(PE_STRIP_CAST_SCRIPT, node)

static func call_on_ready(callable, print_err:bool=true):
	_call_on_ready(PE_STRIP_CAST_SCRIPT, callable, print_err)

func _init(_node):
	pass

func _all_unregistered_callback():
	_join_thread()

func _get_ready_bool() -> bool:
	return is_node_ready()

#endregion

const SHEditor = preload("uid://c4l4v4eufkmtx") #! resolve ALibEditor.Settings.SettingHelperEditor

const GitUtil = preload("res://addons/addon_lib/git_service/src/git_util.gd")
const GitDiff = preload("res://addons/addon_lib/git_service/src/git_diff.gd")
const GlyphIcons = preload("res://addons/addon_lib/git_service/src/glyph_icons.gd")
const GitDataDraw = preload("res://addons/addon_lib/git_service/src/git_data_draw.gd")

const MAIN_REPO = "res://"
const REFRESH_DEBOUNCE = 1.0


signal status_updated(repo_dir:String)
signal commits_updated(repo_dir:String)
signal refresh_finished

var colors:GitColors

var log_commands:bool = false

var setting_helper:SHEditor

var repos:Array[String] = []
var current_repo:String = MAIN_REPO
var _repo_status:Dictionary = {}
var commits:Array[Dictionary] = []

var _repo_for_path:Dictionary = {}

var status:Dictionary:
	get:
		return _repo_status.get(current_repo, {})
	set(_value):
		push_error("GitService.status is read-only — the per-repo map is the truth")

var _thread:Thread
var _debounce_timer:Timer
var _queue:Array[String] = []

var _pending_commands:Array = []


func _ready() -> void:
	_debounce_timer = Timer.new()
	_debounce_timer.one_shot = true
	_debounce_timer.wait_time = REFRESH_DEBOUNCE
	_debounce_timer.timeout.connect(refresh_all)
	add_child(_debounce_timer)

	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_on_filesystem_changed, 1)
	
	setting_helper = SHEditor.new()
	colors = GitColors.new()
	colors.connect_settings(setting_helper)
	setting_helper.subscribe_property(self, &"log_commands", EditorSet.LOG_COMMANDS, false)


	setting_helper.initialize()
	
	_get_glyph_icons_node().warm(GitUtil.get_letter_set())

	refresh_repos()
	if not current_repo in repos:
		current_repo = MAIN_REPO
	refresh_all()


func refresh_repos() -> void:
	var found:Array[String] = GitUtil.find_repos()

	if found == repos:
		return
	repos = found

	for repo_dir:String in _repo_status.keys():
		if not repo_dir in repos:
			_repo_status.erase(repo_dir)

	_repo_for_path.clear()


func set_repo(repo_dir:String) -> void:
	if current_repo == repo_dir:
		return
	var previous_repo = current_repo
	current_repo = repo_dir

	commits = []
	if not _pending_commands.is_empty():
		var dropped:Array = []
		for entry in _pending_commands:
			dropped.append(GitUtil.COMMANDS[entry[0]][GitUtil.Keys.CMD_LABEL])
		push_warning("GitService dropped %d queued command(s) on the switch away from %s: %s" % [
			dropped.size(), previous_repo, ", ".join(dropped)])
	_pending_commands.clear()
	refresh_status()


func get_repo_status(repo_dir:String) -> Dictionary:
	return _repo_status.get(repo_dir, {})

func is_repo(path:String) -> bool:
	return _repo_status.has(path)

func get_repo_for(file_path:String) -> String:
	if not _repo_for_path.has(file_path):
		_repo_for_path[file_path] = GitUtil.find_repo_for(file_path, repos)
	return _repo_for_path[file_path]


func get_file_status(file_path:String) -> Dictionary:
	var repo_dir = get_repo_for(file_path)
	if repo_dir.is_empty():
		return {}
	return get_repo_status(repo_dir).get(GitUtil.Keys.FILES, {}).get(file_path, {})


func is_path_ignored(file_path:String) -> bool:
	var repo_dir = get_repo_for(file_path)
	if repo_dir.is_empty():
		return false
	return GitUtil.is_path_ignored(get_repo_status(repo_dir).get(GitUtil.Keys.IGNORED, []), file_path)


func get_file_color(file_path:String):
	if is_repo(file_path):
		return colors.repo
	var file_data = get_file_status(file_path)
	if not file_data.is_empty():
		return GitUtil.get_status_color(file_data, colors)
	if is_path_ignored(file_path):
		return colors.ignored
	return null


func get_file_severity(file_path:String) -> int:
	var file_data = get_file_status(file_path)
	if file_data.is_empty():
		if is_path_ignored(file_path):
			return GitUtil.Severity.IGNORED
		return GitUtil.Severity.NONE
	return GitUtil.get_status_severity(file_data)


func get_file_letter(file_path:String) -> String:
	return GitUtil.get_status_letter(get_file_status(file_path))


func get_file_icon(file_path:String) -> Texture2D:
	var letter = get_file_letter(file_path)
	if letter.is_empty():
		return null
	return _get_glyph_icons_node().get_letter(letter)


func get_branch() -> Dictionary:
	return status.get(GitUtil.Keys.BRANCH, {})


func get_branch_oid() -> String:
	return get_branch_oid_for(current_repo)


func get_branch_oid_for(repo_dir:String) -> String:
	return get_repo_status(repo_dir).get(GitUtil.Keys.BRANCH, {}).get(GitUtil.Keys.BRANCH_OID, "")


static func get_glyph_icons_node():
	return get_instance()._get_glyph_icons_node()

func _get_glyph_icons_node():
	var glyph_node = get_node_or_null(NodePath(GlyphIcons.NODE_NAME))
	if not is_instance_valid(glyph_node):
		glyph_node = GlyphIcons.new()
		glyph_node.name = GlyphIcons.NODE_NAME
		add_child(glyph_node)
	return glyph_node


func refresh_status() -> void:
	_enqueue(current_repo)
	_pump()


func refresh_all() -> void:
	refresh_repos()
	for repo_dir:String in repos:
		_enqueue(repo_dir)
	_pump()


func run_command(command:GitUtil.Command, paths:Array) -> void:
	if paths.is_empty():
		return

	var expanded = GitUtil.expand_paths(command, paths, status.get(GitUtil.Keys.FILES, {}))
	_pending_commands.append([command, expanded])
	_pump()


func _enqueue(repo_dir:String) -> void:
	if repo_dir.is_empty() or repo_dir in _queue:
		return
	_queue.append(repo_dir)


func _next_repo() -> String:
	if not _pending_commands.is_empty() or current_repo in _queue:
		return current_repo
	return _queue[0] if not _queue.is_empty() else ""


func _pump() -> void:
	if is_instance_valid(_thread) and _thread.is_alive():
		return

	_join_thread()

	var repo_dir = _next_repo()
	if repo_dir.is_empty():
		return
	_queue.erase(repo_dir)

	var full = repo_dir == current_repo
	var queued:Array = []
	if full:
		queued = _pending_commands
		_pending_commands = []

	_thread = Thread.new()
	_thread.start(_status_task.bind(repo_dir, queued, _is_initial(), full))


func _status_task(repo_dir:String, queued:Array, initial:bool, full:bool) -> void:
	var errors:Array = []
	var wrote_worktree = false

	for entry in queued:
		var command:GitUtil.Command = entry[0]
		if log_commands and GitUtil.COMMANDS[command][GitUtil.Keys.CMD_DESTRUCTIVE]:
			print("[GitService] %s: git %s" % [repo_dir,
				" ".join(GitUtil.build_command_args(command, repo_dir, entry[1], initial))])
 
		var result = GitUtil.run_command(repo_dir, command, entry[1], initial)

		if result[GitUtil.Keys.EXIT] != 0:
			errors.append("git %s failed (%s): %s" % [
				GitUtil.COMMANDS[command][GitUtil.Keys.CMD_LABEL],
				result[GitUtil.Keys.EXIT],
				"\n".join(result[GitUtil.Keys.OUTPUT]).strip_edges(),
			])
		elif GitUtil.COMMANDS[command][GitUtil.Keys.CMD_WORKTREE]:
			wrote_worktree = true

	var status_result = GitUtil.get_status(repo_dir)
	var log_result:Array = []

	if full:
		GitUtil.attach_diffs(repo_dir, status_result)
		log_result = GitUtil.get_log(repo_dir)
	
	_on_status_ready.call_deferred(repo_dir, status_result, log_result, errors, wrote_worktree, full)


func _on_status_ready(repo_dir:String, status_result:Dictionary, log_result:Array, errors:Array,
		wrote_worktree:bool, full:bool) -> void:
	_join_thread()

	for error:String in errors:
		push_error(error)

	if repo_dir in repos:
		_repo_status[repo_dir] = status_result
		status_updated.emit(repo_dir)
	
		if full and repo_dir == current_repo:
			commits.assign(log_result)
			commits_updated.emit(repo_dir)
	 
	if wrote_worktree:
		EditorInterface.get_script_editor().notification(NOTIFICATION_APPLICATION_FOCUS_IN)

	_pump()

	if not is_instance_valid(_thread):
		refresh_finished.emit()


func _join_thread() -> void:
	if not is_instance_valid(_thread):
		return
	_thread.wait_to_finish()
	_thread = null

func _is_initial() -> bool:
	return get_branch().get(GitUtil.Keys.BRANCH_INITIAL, false)

func _on_filesystem_changed() -> void:
	_debounce_timer.start()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_debounce_timer.start()

class GitColors:
	var conflicted:Color = GitUtil.Colors.RED
	var staged:Color = GitUtil.Colors.GREEN
	var modified:Color = GitUtil.Colors.L_YELLOW
	var untracked:Color = GitUtil.Colors.L_GREEN
	var ignored:Color = GitUtil.Colors.DIM
	var repo:Color = GitUtil.Colors.REPO
	
	
	func connect_settings(setting_helper:SHEditor):
		setting_helper.subscribe_property(self, &"conflicted", EditorSet.CONFLICTED, GitUtil.Colors.RED)
		setting_helper.subscribe_property(self, &"staged", EditorSet.STAGED, GitUtil.Colors.GREEN)
		setting_helper.subscribe_property(self, &"modified", EditorSet.MODIFIED, GitUtil.Colors.L_YELLOW)
		setting_helper.subscribe_property(self, &"untracked", EditorSet.UNTRACKED, GitUtil.Colors.L_GREEN)
		setting_helper.subscribe_property(self, &"ignored", EditorSet.IGNORED, GitUtil.Colors.DIM)
		setting_helper.subscribe_property(self, &"repo", EditorSet.REPO, GitUtil.Colors.REPO)
	

class EditorSet:
	const CONFLICTED = &"plugin/git_view/color/conflicted"
	const STAGED = &"plugin/git_view/color/staged"
	const MODIFIED = &"plugin/git_view/color/modified"
	const UNTRACKED = &"plugin/git_view/color/untracked"
	const IGNORED = &"plugin/git_view/color/ignored"
	const REPO = &"plugin/git_view/color/repo"

	const LOG_COMMANDS = &"plugin/git_view/log_destructive_commands"
