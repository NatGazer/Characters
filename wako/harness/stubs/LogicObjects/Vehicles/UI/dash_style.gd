extends RefCounted
## Harness stub for RaulsMod's vehicle dash style: Wako only asks for a caption font.
static var _fonts := {}
static func font(weight := "regular") -> Font:
	if not _fonts.has(weight):
		var f := SystemFont.new()
		f.font_weight = 600 if weight == "semi" else 400
		_fonts[weight] = f
	return _fonts[weight]
