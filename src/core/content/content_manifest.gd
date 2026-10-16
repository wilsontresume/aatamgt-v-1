class_name ContentManifest
extends RefCounted
## Phase E: parsed published content manifest (server ContentPublication).
##
## The public endpoint returns an envelope:
##   { version, checksum, publishedAt, manifest: DraftManifest }
## The inner manifest is the frozen draft built server-side:
##   { version, generatedAt, home, games[], tiers[], assets{id: {...}} }
## This class is a tolerant read-only view over that data. Missing or
## malformed pieces resolve to empty values so callers never branch on
## null — procedural defaults always remain the fallback.

const SCREEN_TO_GAME_KEY := {
	"aadu_puli": "aadu-puli-aattam",
	"solah_seedi": "solah-seedi",
	"nine_mens_morris": "nine-mens-morris",
}

const HEX_COLOR := "^#[0-9a-fA-F]{6,8}$"
const ASSET_ID := "^ga[0-9a-f]{20,64}$"

var envelope_version := 0
var envelope_checksum := ""
var envelope_published_at := ""
var manifest_version := 0
var generated_at := ""
var raw := {}


static func screen_game_key(screen_id: String) -> String:
	return str(SCREEN_TO_GAME_KEY.get(screen_id, screen_id))


## Parses one publication envelope. Returns an empty manifest (version 0)
## when the payload is not a usable publication.
static func parse_envelope(envelope: Dictionary) -> ContentManifest:
	var m := ContentManifest.new()
	var manifest: Variant = envelope.get("manifest")
	if not (manifest is Dictionary):
		# Tolerate a bare manifest (tests, hand-written fixtures).
		manifest = envelope
	if not (manifest is Dictionary):
		return m
	var body := manifest as Dictionary
	if not body.has("games") or not (body["games"] is Array):
		return m
	m.raw = body
	m.envelope_version = int(envelope.get("version", body.get("version", 0)))
	m.envelope_checksum = str(envelope.get("checksum", ""))
	m.envelope_published_at = str(envelope.get("publishedAt",
			envelope.get("generatedAt", "")))
	m.manifest_version = int(body.get("version", 0))
	m.generated_at = str(body.get("generatedAt", ""))
	return m


static func from_cache_file(path: String) -> ContentManifest:
	if not FileAccess.file_exists(path):
		return ContentManifest.new()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ContentManifest.new()
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return ContentManifest.new()
	return parse_envelope(parsed as Dictionary)


func is_empty() -> bool:
	return raw.is_empty()


## sha256 hex of `bytes` (64 lowercase hex chars). Used to verify
## downloaded asset files against the manifest checksum.
static func sha256_hex(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if ctx.update(bytes) != OK:
		return ""
	var digest := ctx.finish()
	var hex := ""
	for b in digest:
		hex += "%02x" % b
	return hex


## True when `hex` is a well-formed #rrggbb color string.
static func is_hex_color(value: String) -> bool:
	if value.length() != 7 or value[0] != "#":
		return false
	for i in range(1, 7):
		if not "0123456789abcdefABCDEF".contains(value[i]):
			return false
	return true


## True when `id` looks like a server asset id (blocks path traversal).
static func is_asset_id(id: String) -> bool:
	return id.length() == 30 and id.begins_with("ga") \
			and id.substr(2).is_valid_hex_number(false)


# --- Section accessors -------------------------------------------------------

func games() -> Array:
	if raw.is_empty():
		return []
	var games: Variant = raw.get("games", [])
	return games if games is Array else []


## Game entries ordered by the server's displayOrder (ties keep server order).
func games_ordered() -> Array:
	return games()


func game_entry(game_key: String) -> Dictionary:
	for entry in games():
		if entry is Dictionary and str((entry as Dictionary).get("key", "")) == game_key:
			return entry
	return {}


func tiers() -> Array:
	if raw.is_empty():
		return []
	var tiers: Variant = raw.get("tiers", [])
	return tiers if tiers is Array else []


func tier_entry(tier_id: String) -> Dictionary:
	for entry in tiers():
		if entry is Dictionary and str((entry as Dictionary).get("id", "")) == tier_id:
			return entry
	return {}


func asset_entry(asset_id: String) -> Dictionary:
	if asset_id.is_empty() or raw.is_empty():
		return {}
	var assets: Variant = raw.get("assets", {})
	if not (assets is Dictionary):
		return {}
	var entry: Variant = (assets as Dictionary).get(asset_id)
	return entry if entry is Dictionary else {}


func asset_checksum(asset_id: String) -> String:
	return str(asset_entry(asset_id).get("checksum", ""))


## AssetRef id from a {id: ...} ref (or "" when absent).
static func ref_id(ref: Variant) -> String:
	if ref is Dictionary:
		return str((ref as Dictionary).get("id", ""))
	return ""


func home_background_id() -> String:
	if raw.is_empty():
		return ""
	var home: Variant = raw.get("home", {})
	if not (home is Dictionary):
		return ""
	return ref_id((home as Dictionary).get("background"))


## Board presentation colors for a game: {bg, line, accent} as Colors.
## Only valid #rrggbb entries are included; callers fall back per-key.
func board_skin(game_key: String) -> Dictionary:
	var theme := board_theme(game_key)
	var out := {}
	var bg: Variant = _parse_color(str(theme.get("surfaceColor", "")))
	if bg != null:
		out["bg"] = bg
	var line: Variant = _parse_color(str(theme.get("borderColor", "")))
	if line != null:
		out["line"] = line
	var accent: Variant = _parse_color(str(theme.get("accentColor", "")))
	if accent != null:
		out["accent"] = accent
	return out


func board_theme(game_key: String) -> Dictionary:
	var entry := game_entry(game_key)
	var theme: Variant = entry.get("boardTheme", {})
	return theme if theme is Dictionary else {}


func board_background_id(game_key: String) -> String:
	return ref_id(board_theme(game_key).get("background"))


func board_texture_id(game_key: String) -> String:
	return ref_id(board_theme(game_key).get("texture"))


func board_piece_id(game_key: String) -> String:
	return ref_id(board_theme(game_key).get("piece"))


func game_card_id(game_key: String) -> String:
	return ref_id(game_entry(game_key).get("card"))


func game_icon_id(game_key: String) -> String:
	return ref_id(game_entry(game_key).get("icon"))


func game_background_id(game_key: String) -> String:
	return ref_id(game_entry(game_key).get("background"))


## Display fields for a tier card (visuals only; costs come from the API).
## {name, description, color (Color or null), art_id} — empty when unknown.
func tier_display(tier_id: String) -> Dictionary:
	var entry := tier_entry(tier_id)
	if entry.is_empty():
		return {}
	return {
		"name": str(entry.get("name", entry.get("id", ""))),
		"description": str(entry.get("description", "")),
		"color": _parse_color(str(entry.get("color", ""))),
		"art_id": ref_id(entry.get("art")),
	}


## Tier display by human label ("Bronze" / "Silver" / "Gold") when the
## client only has the label from the matchmaking API.
func tier_display_by_name(tier_name: String) -> Dictionary:
	var want := tier_name.strip_edges().to_lower()
	if want.is_empty():
		return {}
	for entry in tiers():
		if not (entry is Dictionary):
			continue
		var name := str((entry as Dictionary).get("name", "")).to_lower()
		if name == want:
			return tier_display(str((entry as Dictionary).get("id", "")))
	return {}


static func _parse_color(hex: String) -> Variant:
	var value := hex.strip_edges()
	if value.is_empty() or not is_hex_color(value):
		return null
	return Color.html(value)
