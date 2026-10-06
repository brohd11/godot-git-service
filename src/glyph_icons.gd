extends Node

## rasterizes status letters into square textures for Tree and ItemList.
## uses the viewport draw path so editor fonts always work.

const NODE_NAME = &"GlyphIcons"

const PAD = 1
const MIN_SIDE = 12

var _cache:Dictionary = {}
var _side:int = 0

signal generated

var _key:String = ""
var _chars:String = ""
var _warming:bool = false

func get_letter(letter:String) -> Texture2D:
	return _cache.get(letter)

func get_side() -> int:
	return _side

func _ready() -> void:
	EditorInterface.get_editor_settings().settings_changed.connect(_on_editor_settings_changed)

func warm(chars:String) -> void:
	if _warming or chars.is_empty():
		return

	_chars = chars
	var font = EditorInterface.get_editor_theme().get_font(&"main", &"EditorFonts")
	var font_size = EditorInterface.get_editor_theme().get_font_size(&"main_size", &"EditorFonts")
	if font == null or font_size <= 0:
		return

	var key = _make_key(font, font_size)
	if key == _key and not _cache.is_empty():
		return

	_warming = true
	var baked = await _rasterize(chars, font, font_size)
	_warming = false

	if baked.is_empty():
		return # a failed bake leaves the old cache up rather than blanking every row

	_cache = baked[&"textures"]
	_side = baked[&"side"]
	_key = key
	generated.emit()


func _rasterize(chars:String, font:Font, font_size:int) -> Dictionary:
	var cell = int(ceil(font.get_height(font_size) * 2.0))
	if cell <= 0:
		return {}

	var count = chars.length()

	var viewport = SubViewport.new()
	viewport.size = Vector2i(cell * count, cell)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	var canvas = Control.new()
	canvas.size = viewport.size
	canvas.draw.connect(func():
		for i in count:
			canvas.draw_char(font, Vector2(i * cell + cell * 0.25, cell * 0.75), chars[i],
				font_size, Color.WHITE)
	)

	viewport.add_child(canvas)
	add_child(viewport)

	await RenderingServer.frame_post_draw

	var strip:Image = viewport.get_texture().get_image()
	viewport.queue_free()

	if strip == null:
		return {}
	if strip.is_compressed():
		strip.decompress()
	strip.convert(Image.FORMAT_RGBA8)

	var cells:Array[Image] = []
	var inks:Array[Rect2i] = []
	var side = 0

	for i in count:
		var cell_image = strip.get_region(Rect2i(i * cell, 0, cell, cell))
		var ink = cell_image.get_used_rect()
		cells.append(cell_image)
		inks.append(ink)
		side = maxi(side, maxi(ink.size.x, ink.size.y))

	var scale = EditorInterface.get_editor_scale()
	side += int(2 * PAD * scale)
	side = maxi(side, int(MIN_SIDE * scale))

	var textures := {}
	for i in count:
		var ink:Rect2i = inks[i]
		if ink.size.x <= 0 or ink.size.y <= 0:
			continue # the font has no glyph for this character; leave it out and let the caller fall back

		var square = Image.create_empty(side, side, false, Image.FORMAT_RGBA8)
		square.fill(Color(1, 1, 1, 0))
		square.blit_rect(cells[i], ink, Vector2i(
			int((side - ink.size.x) / 2.0),
			int((side - ink.size.y) / 2.0),
		))
		_force_white(square)
		textures[chars[i]] = ImageTexture.create_from_image(square)

	return {&"textures": textures, &"side": side}


func _force_white(image:Image) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var alpha = image.get_pixel(x, y).a
			if alpha > 0.0:
				image.set_pixel(x, y, Color(1, 1, 1, alpha))


func _make_key(font:Font, font_size:int) -> String:
	return "%d|%d|%.2f" % [font.get_instance_id(), font_size, EditorInterface.get_editor_scale()]


func _on_editor_settings_changed() -> void:
	if _warming or _chars.is_empty():
		return

	var font = EditorInterface.get_editor_theme().get_font(&"main", &"EditorFonts")
	var font_size = EditorInterface.get_editor_theme().get_font_size(&"main_size", &"EditorFonts")
	if font == null or _make_key(font, font_size) == _key:
		return # the settings that moved were not ones the squares are baked against

	warm(_chars)
