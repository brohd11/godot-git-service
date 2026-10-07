extends RefCounted

## shared status drawing helpers for Tree and ItemList.

const UTree = preload("uid://1gwputufojp6") #! resolve UtilR.Nodes.Trees.UTree
const NUItemList = preload("uid://cjls86v1v4242") #! resolve ALibRuntime.NodeUtils.NUItemList
const TreeHelperBase = preload("uid://bm6fl2iu4jew7") #! resolve ALibRuntime.TreeHelperBase
const FAVORITES_META = "FAVORITES" #! resolve FileSystemSingleton.FileData.FAVORITES_META

const GitUtil = preload("res://addons/_lib/git_service/src/git_util.gd")


class GitItemHelper:
	var git_service:GitService
	var _item_list:ItemList
	
	var set_fg_color:= true
	
	var color_ignored:=true
	
	func _init(item_list:ItemList) -> void:
		git_service = GitService.get_instance()
		
		_item_list = item_list
		_item_list.draw.connect(_on_item_list_drawn)
	
	func _on_item_list_drawn():
		var list_rect = _item_list.get_rect()
		var scroll_pos = _item_list.get_v_scroll_bar().value
		
		var margin = _item_list.get_theme_constant("h_separation") * 2
		
		for i in range(_item_list.item_count):
			var item_rect = _item_list.get_item_rect(i)
			item_rect.position.y -= scroll_pos
			if item_rect.position.y + item_rect.size.y < 0 or item_rect.position.y > list_rect.size.y:
				continue 
			
			var item_path = _get_path_from_item(i)
			
			var color = git_service.get_file_color(item_path)
			if color == null:
				continue
			var icon = git_service.get_file_icon(item_path)
			if icon == null:
				continue
			
			if NUItemList.item_text_overflows(_item_list, i, icon):
				var sq_sz = item_rect.size.y * 0.25
				var trip_x = item_rect.position.x + item_rect.size.x + (icon.get_width() / 2.0) - margin
				var trip_y = item_rect.position.y + item_rect.size.y * 0.25
				var tri = [
					Vector2(trip_x - sq_sz, trip_y),
					Vector2(trip_x, trip_y),
					Vector2(trip_x, trip_y + sq_sz),
				]
				_item_list.draw_colored_polygon(tri, color)
				continue
			
			var icon_rect = Util.get_icon_rect(item_rect, icon, margin)
			_item_list.draw_texture_rect(icon, icon_rect, false, color)
	
	func set_item_fg_color(idx:int, path:String):
		var color = git_service.get_file_color(path)
		if color == null:
			return
		if not color_ignored and git_service.get_file_severity(path) == GitService.GitUtil.Severity.IGNORED:
			return
		_item_list.set_item_custom_fg_color(idx, color)
	
	func _get_path_from_item(idx:int):
		var meta = _item_list.get_item_metadata(idx)
		if meta is String:
			return meta
		else:
			return _item_list.get_item_tooltip(idx)


class GitTreeHelper:
	
	
	var git_service:GitService
	var _tree:Tree
	var _overlay:Control
	var _overlay_icons:= []
	
	var marker_icon:Texture2D
	
	func _init(tree) -> void:
		git_service = GitService.get_instance()
		
		_tree = tree
		_tree.draw.connect(_on_tree_draw)
		_overlay = Control.new()
		_tree.add_child(_overlay)
		_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_overlay.draw.connect(_draw_icon_overlay)
		
		marker_icon = Util.get_marker_icon()
	
	func reprocess_tree():
		var item:TreeItem = _tree.get_root()
		while is_instance_valid(item):
			for key in [Keys.GIT_ICON, Keys.OWN_COLOR, Keys.IS_REPO]:
				if item.has_meta(key):
					item.remove_meta(key)
				item.clear_custom_color(0)
			var meta = item.get_metadata(0)
			if meta != null and meta.has(TreeHelperBase.Keys.METADATA_PATH):
				var path = meta.get(TreeHelperBase.Keys.METADATA_PATH)
				if path != FAVORITES_META:
					process_tree_item(path, item)
			
			item = item.get_next_in_tree()
	
	func process_tree_item(file_path:String, tree_item:TreeItem):
		var color = git_service.get_file_color(file_path)
		if color == null:
			return
		
		
		tree_item.set_custom_color(0, color)
		if file_path.ends_with("/") and git_service.is_repo(file_path):
			tree_item.set_meta(Keys.IS_REPO, true)
			
		tree_item.set_meta(Keys.OWN_COLOR, true)
		var icon = git_service.get_file_icon(file_path)
		if icon == null:
			return
		
		var severity = git_service.get_file_severity(file_path)
		_set_item_meta(tree_item, icon, color, severity)
		
		var par = tree_item.get_parent()
		while is_instance_valid(par):
			if _set_item_meta(par, marker_icon, color, severity):
				if not par.has_meta(Keys.OWN_COLOR):
					par.set_custom_color(0, color)
			
			if par.has_meta(Keys.IS_REPO):
				color = git_service.colors.repo
				severity = GitUtil.Severity.NESTED
			
			par = par.get_parent()
	
	func _on_tree_draw():
		_overlay_icons.clear()
		
		var root = _tree.get_root()
		if not is_instance_valid(root):
			return
		
		var tree_rect = _tree.get_rect()
		var icon_margin = _tree.get_theme_constant(&"icon_h_separation") * 2
		
		var next_item = root.get_next_visible()
		while is_instance_valid(next_item):
			var current_item = next_item
			next_item = next_item.get_next_visible()
			
			if not current_item.has_meta(Keys.GIT_ICON):
				continue
			var current_rect = _tree.get_item_area_rect(current_item, 0)
			if current_rect.position.y < 0 - current_rect.size.y or current_rect.position.y > tree_rect.size.y:
				continue
			
			
			var meta = current_item.get_meta(Keys.GIT_ICON)
			var icon:Texture2D = meta.icon
			
			if UTree.item_text_overflows(_tree, current_item, icon):
				continue
			
			_overlay_icons.append({
				Keys.RECT: Util.get_icon_rect(current_rect, icon, icon_margin),
				Keys.ICON: icon,
				Keys.COLOR: meta.color
			})
			
		_overlay.queue_redraw()

	func _draw_icon_overlay():
		for data in _overlay_icons:
			_overlay.draw_texture_rect(
				data.get(Keys.ICON), 
				data.get(Keys.RECT), 
				false, 
				data.get(Keys.COLOR))
	
	func _set_item_meta(tree_item:TreeItem, icon:Texture2D, color:Color, severity:int) -> bool:
		var existing:Dictionary = tree_item.get_meta(Keys.GIT_ICON, {})
		if int(existing.get(Keys.SEVERITY, GitUtil.Severity.NONE)) >= severity:
			return false
		tree_item.set_meta(Keys.GIT_ICON, {
			Keys.ICON: icon,
			Keys.COLOR: color,
			Keys.SEVERITY: severity,
		})
		return true

class Util:
	static func get_icon_rect(rect:Rect2, icon:Texture2D, margin:int):
		rect.position.x += rect.size.x - (icon.get_size().x / 2.0) - margin
		rect.position.y += (rect.size.y - icon.get_size().y) / 2.0
		rect.size = icon.get_size()
		return rect
	
	static func get_marker_icon():
		return EditorInterface.get_editor_theme().get_icon(&"Breakpoint", &"EditorIcons")

class Keys:
	const GIT_ICON = &"git_icon"
	const OWN_COLOR = &"own_color"
	const IS_REPO = &"repo"
	
	const RECT = &"rect"
	const ICON = &"icon"
	const COLOR = &"color"
	const SEVERITY = &"severity"
