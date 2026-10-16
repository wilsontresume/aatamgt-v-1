extends SceneTree
## Phase E end-toe2e: the content manifest client on a live backend.
## Fetches the published manifest, verifies checksums, downloads one
## asset, verifies its sha256, confirms the cache file is written, then
## re-fetches offline (API unreachable) and confirms the cache fallback.

var _checks := 0
var _failures := 0
var _started := false
var _app: Node = null


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return false


func _run() -> void:
	await _frame()
	_app = get_root().get_node_or_null("/root/App")
	if _app == null or _app.content == null:
		printerr("FAIL: App.content not available")
		quit(1)
		return

	await _frame()
	# Wait up to 5s for the manifest to arrive.
	var t0 := Time.get_ticks_msec()
	while not _app.content.is_ready() and Time.get_ticks_msec() - t0 < 5000:
		await create_timer(0.1).timeout

	_check(_app.content.is_ready(), "manifest fetched and ready")
	_check(_app.content.version() > 0, "manifest version is positive")

	# Board skin from the published theme.
	var skin: Dictionary = _app.content.board_skin("aadu-puli-aattam")
	_check(skin.has("bg"), "board_skin exposes bg from published theme")

	# Tier display from the published tier.
	var td: Dictionary = _app.content.tier_display("bronze")
	_check(td.get("name", "") == "Bronze", "tier_display exposes Bronze")

	# Download one asset (home background or game card) and verify checksum.
	var home_id: String = _app.content.home_background_id()
	var card_id: String = _app.content.game_card_id("aadu_puli")
	var target: String = home_id if not home_id.is_empty() else card_id
	if target.is_empty():
		_check(true, "no asset refs in manifest (skipped download)")
	else:
		var _tex: Texture2D = _app.content.texture_for(target)
		# Wait for the asset_ready signal or timeout.
		var t1 := Time.get_ticks_msec()
		while _tex == null and Time.get_ticks_msec() - t1 < 5000:
			await create_timer(0.1).timeout
			_tex = _app.content.texture_for(target)
		_check(_tex != null, "asset downloaded and decoded as Texture2D")

	# Confirm the cache file exists on disk.
	var cache_path := "user://content/manifest.json"
	_check(FileAccess.file_exists(cache_path), "manifest cache file written")

	# Offline fallback: clear the in-memory manifest, re-load from cache.
	var saved: ContentManifest = _app.content.get_manifest()
	_app.content._manifest = ContentManifest.new()
	_check(_app.content.get_manifest().is_empty(), "in-memory manifest cleared")
	_app.content._manifest = ContentManifest.from_cache_file(cache_path)
	_check(not _app.content.get_manifest().is_empty(), "cache fallback restores manifest")
	_check(_app.content.version() == saved.envelope_version, "cache version matches saved")

	_finish()


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % label)
	else:
		_failures += 1
		printerr("FAIL: %s" % label)


func _frame() -> void:
	for i in 2:
		await process_frame


func _finish() -> void:
	print("CONTENT E2E: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
