class_name ContentService
extends RefCounted
## Phase E: published content manifest client (fetch, cache, fallback).
##
## On start() the last cached publication is loaded immediately so
## boards/cards/tiers have data offline or on first boot. refresh()
## then fetches the public manifest over the API; a successful fetch
## is checksum-compared against the cache and persisted atomically to
## user://content/manifest.json. Every accessor degrades to empty —
## callers keep their bundled procedural defaults.

signal manifest_changed
signal asset_ready(asset_id: String)
signal refresh_finished(ok: bool)

const CACHE_DIR := "user://content"
const CACHE_PATH := "user://content/manifest.json"
const ASSET_DIR := "user://content/assets"
const TIMEOUT_SECONDS := 20.0

const MANIFEST_PATH := "/content/manifest"

var _api: ApiClient
var _manifest := ContentManifest.new()
var _textures: Dictionary = {}   # asset_id -> Texture2D
var _pending: Dictionary = {}    # asset_id -> true while downloading


func _init(api_client: ApiClient) -> void:
	_api = api_client


## Loads the cached publication and kicks a network refresh. Safe to
## call once from App after configure_backend().
func start() -> void:
	_ensure_dirs()
	var cached := ContentManifest.from_cache_file(CACHE_PATH)
	if not cached.is_empty():
		_manifest = cached
		manifest_changed.emit()
	refresh()


## Fetches the published manifest. Returns true when fresh data was
## installed. Awaiting.
func refresh() -> bool:
	if _api == null or not _api.is_configured():
		refresh_finished.emit(false)
		return false
	var res: Dictionary = await _api.request_json(HTTPClient.METHOD_GET, MANIFEST_PATH)
	if not res.get("ok", false) or not (res.get("body") is Dictionary):
		refresh_finished.emit(false)
		return false
	var body: Dictionary = res["body"]
	var parsed := ContentManifest.parse_envelope(body)
	if parsed.is_empty():
		refresh_finished.emit(false)
		return false
	# Skip a no-op write when the checksum already matches the cache.
	if parsed.envelope_checksum != _manifest.envelope_checksum:
		_manifest = parsed
		_write_cache(body)
		_textures.clear()   # new publication may reference new versions
		manifest_changed.emit()
	refresh_finished.emit(true)
	return true


func get_manifest() -> ContentManifest:
	return _manifest


func version() -> int:
	return _manifest.envelope_version


func is_ready() -> bool:
	return not _manifest.is_empty()


# --- Visual accessors (thin passthroughs; empty = procedural default) ------

func board_skin(game_key: String) -> Dictionary:
	return _manifest.board_skin(game_key)


func home_background_id() -> String:
	return _manifest.home_background_id()


func game_card_id(screen_or_key: String) -> String:
	return _manifest.game_card_id(ContentManifest.screen_game_key(screen_or_key))


func tier_display(tier_id: String) -> Dictionary:
	return _manifest.tier_display(tier_id)


func tier_display_by_name(tier_name: String) -> Dictionary:
	return _manifest.tier_display_by_name(tier_name)


## Texture for an asset id, or null. Starts a background download when
## the manifest references the asset and nothing is cached yet.
func texture_for(asset_id: String) -> Texture2D:
	if asset_id.is_empty() or not ContentManifest.is_asset_id(asset_id):
		return null
	if _textures.has(asset_id):
		return _textures[asset_id]
	var path := _asset_cache_path(asset_id)
	var bytes := _read_file(path)
	if bytes.is_empty():
		_download_asset(asset_id)
		return null
	var tex := _texture_from_bytes(bytes, _mime_of(asset_id))
	if tex == null:
		# Corrupt cache — drop it and retry once over the network.
		_erase_file(path)
		_download_asset(asset_id)
		return null
	_textures[asset_id] = tex
	return tex


## Texture for a screen id or game key (card art), or null.
func card_texture(screen_or_key: String) -> Texture2D:
	return texture_for(game_card_id(screen_or_key))


func home_texture() -> Texture2D:
	return texture_for(home_background_id())


## Tier art texture by tier id, or null.
func tier_art_texture(tier_id: String) -> Texture2D:
	return texture_for(str(_manifest.tier_display(tier_id).get("art_id", "")))


# --- Asset downloads ---------------------------------------------------------

func _download_asset(asset_id: String) -> void:
	if _pending.get(asset_id, false):
		return
	if _api == null or not _api.is_configured():
		return
	var entry := _manifest.asset_entry(asset_id)
	if entry.is_empty():
		return
	var url := str(entry.get("url", ""))
	if url.is_empty():
		return
	if url.begins_with("/"):
		url = _api.get_base_url() + url
	elif not url.begins_with("https://") and not url.begins_with("http://"):
		return
	_pending[asset_id] = true
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SECONDS
	_api._apply_tls(http)
	_api.add_child(http)
	var start_error := http.request(url, PackedStringArray(["Accept: application/octet-stream"]))
	if start_error != OK:
		http.queue_free()
		_pending.erase(asset_id)
		return
	var response: Array = await http.request_completed
	http.queue_free()
	_pending.erase(asset_id)
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		return
	var bytes: PackedByteArray = response[3]
	if bytes.is_empty():
		return
	# Verify against the manifest checksum before trusting the file.
	var expected := str(entry.get("checksum", ""))
	if not expected.is_empty() and ContentManifest.sha256_hex(bytes) != expected:
		push_warning("ContentService: checksum mismatch for %s — discarded" % asset_id)
		return
	_write_file(_asset_cache_path(asset_id), bytes)
	var tex := _texture_from_bytes(bytes, str(entry.get("mimeType", "")))
	if tex != null:
		_textures[asset_id] = tex
		asset_ready.emit(asset_id)


func _texture_from_bytes(bytes: PackedByteArray, mime: String) -> Texture2D:
	if bytes.is_empty():
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if mime.contains("png") or mime.is_empty():
		err = img.load_png_from_buffer(bytes)
		if err != OK and mime.is_empty():
			err = img.load_jpg_from_buffer(bytes)
			if err != OK:
				err = img.load_webp_from_buffer(bytes)
	elif mime.contains("jpeg") or mime.contains("jpg"):
		err = img.load_jpg_from_buffer(bytes)
	elif mime.contains("webp"):
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


func _mime_of(asset_id: String) -> String:
	return str(_manifest.asset_entry(asset_id).get("mimeType", ""))


# --- File helpers ------------------------------------------------------------

func _ensure_dirs() -> void:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	if not DirAccess.dir_exists_absolute(ASSET_DIR):
		DirAccess.make_dir_recursive_absolute(ASSET_DIR)


func _write_cache(envelope: Dictionary) -> void:
	_write_file(CACHE_PATH, JSON.stringify(envelope).to_utf8_buffer())


func _asset_cache_path(asset_id: String) -> String:
	return "%s/%s" % [ASSET_DIR, asset_id]


func _read_file(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return bytes


func _write_file(path: String, bytes: PackedByteArray) -> void:
	_ensure_dirs()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()


func _erase_file(path: String) -> void:
	if FileAccess.file_exists(path):
		var dir := DirAccess.open(path.get_base_dir())
		if dir != null:
			dir.remove(path.get_file())
	_textures.erase(path.get_file())
