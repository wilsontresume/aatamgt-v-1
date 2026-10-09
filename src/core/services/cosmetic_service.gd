class_name CosmeticService
extends RefCounted
## Phase 12: server-owned cosmetic inventory (display + commands only).
##
## Ownership, equipped state, tiers and prices always come from the
## server via GET /cosmetics. This service caches that payload for
## rendering, forwards the allowed actions (claim / purchase / equip /
## dev-grant) and never computes or mutates inventory itself. The
## local dictionaries below are presentation hints only — colours and
## labels for things the server already told us exist.

signal inventory_changed

const CATEGORY_ORDER := [
	"BOARD_SKIN",
	"PROFILE_PICTURE",
	"PROFILE_FRAME",
	"VICTORY_ANIMATION",
	"CAPTURE_ANIMATION",
]
const CATEGORY_TITLES := {
	"BOARD_SKIN": "Board skins",
	"PROFILE_PICTURE": "Profile pictures",
	"PROFILE_FRAME": "Profile frames",
	"VICTORY_ANIMATION": "Victory animations",
	"CAPTURE_ANIMATION": "Capture animations",
}

# --- Presentation palettes (client-only colours for equipped keys) ---------

const BOARD_PALETTES := {
	"board_woodland": {"bg": Color("1d2a1e"), "line": Color("7a9464")},
	"board_midnight": {"bg": Color("131733"), "line": Color("8f9bd4")},
}

const PFP_STYLES := {
	"pfp_sunset": {"fill": Color("b3543f"), "accent": Color("f2c665")},
	"pfp_nebula": {"fill": Color("3d2f6b"), "accent": Color("9b7ede")},
}

const FRAME_STYLES := {
	"frame_silver": {"color": Color("c7d0da"), "width": 3.0},
	"frame_gold": {"color": Color("e8b54a"), "width": 3.0},
}

const VICTORY_STYLES := {
	"victory_confetti": {
		"kind": "confetti",
		"colors": [Color("e5484d"), Color("46a758"), Color("e8b54a"),
				Color("5b8def"), Color("f2f5f8")],
	},
	"victory_fireworks": {
		"kind": "fireworks",
		"colors": [Color("e8b54a"), Color("f2c665"), Color("fff4d6"),
				Color("e5484d")],
	},
}

const CAPTURE_STYLES := {
	"capture_flash": {"kind": "flash", "color": Color("f2f5f8")},
	"capture_shockwave": {"kind": "shockwave", "color": Color("e8b54a")},
}

var items: Array = []          # server item dicts, in server order
var dev_grants_enabled := false
var loaded := false

var _auth: AuthService
var _coins: CoinService


func _init(p_auth: AuthService, p_coins: CoinService) -> void:
	_auth = p_auth
	_coins = p_coins


# --- Server commands --------------------------------------------------------

## GET /cosmetics → caches {items, devGrantsEnabled} and notifies views.
func refresh() -> Dictionary:
	var res: Dictionary = await _auth.authenticated_get("/cosmetics")
	if res.ok and res.body is Dictionary:
		var body: Dictionary = res.body
		var raw: Variant = body.get("items", [])
		items = raw if raw is Array else []
		dev_grants_enabled = bool(body.get("devGrantsEnabled", false))
		loaded = true
		inventory_changed.emit()
	return res


## FREE cosmetics: server records the grant.
func claim(key: String) -> Dictionary:
	return await _mutate("/cosmetics/%s/claim" % key)


## PREMIUM cosmetics: the server debits coins; the returned balance is
## the authoritative ledger value and is the only input allowed into
## CoinService from this flow.
func purchase(key: String) -> Dictionary:
	var res: Dictionary = await _mutate("/cosmetics/%s/purchase" % key, false)
	if res.ok:
		if res.body is Dictionary and (res.body as Dictionary).has("balance"):
			_coins.set_balance_from_server(
					int((res.body as Dictionary).get("balance", 0)))
		await refresh()  # authoritative: refetch after a successful purchase
	return res


## Equip requires ownership; the server switches within the category.
func equip(key: String) -> Dictionary:
	return await _mutate("/cosmetics/%s/equip" % key)


## Development-only grant; the server 404s when the flag is off.
func dev_grant(key: String) -> Dictionary:
	return await _mutate("/cosmetics/%s/grant" % key)


## Drops another account's inventory (called on sign-out).
func clear() -> void:
	items = []
	dev_grants_enabled = false
	loaded = false
	inventory_changed.emit()


func _mutate(path: String, reload_after: bool = true) -> Dictionary:
	var res: Dictionary = await _auth.authenticated_post(path, {})
	if res.ok and reload_after:
		await refresh()  # server is the source of truth — re-pull
	return res


# --- Read helpers ------------------------------------------------------------

static func state_of(item: Dictionary) -> String:
	if bool(item.get("equipped", false)):
		return "equipped"
	if bool(item.get("owned", false)):
		return "owned"
	return "locked"


static func tier_label(item: Dictionary) -> String:
	if str(item.get("tier", "FREE")) == "PREMIUM":
		return "%d coins" % int(item.get("price", 0))
	return "Free"


static func is_premium(item: Dictionary) -> bool:
	return str(item.get("tier", "FREE")) == "PREMIUM"


func equipped_key(category: String) -> String:
	for item in items:
		if str(item.get("category", "")) == category \
				and bool(item.get("equipped", false)):
			return str(item.get("key", ""))
	return ""


func items_in_category(category: String) -> Array:
	var out: Array = []
	for item in items:
		if str(item.get("category", "")) == category:
			out.append(item)
	return out


# --- Presentation lookups (pure functions over equipped keys) ----------------

static func board_palette(key: String) -> Dictionary:
	return BOARD_PALETTES.get(key, {})


static func pfp_style(key: String) -> Dictionary:
	return PFP_STYLES.get(key, {})


static func frame_style(key: String) -> Dictionary:
	return FRAME_STYLES.get(key, {})


static func victory_style(key: String) -> Dictionary:
	return VICTORY_STYLES.get(key, {})


static func capture_style(key: String) -> Dictionary:
	return CAPTURE_STYLES.get(key, {})


## Pushes the equipped board palette onto a board control. Offline (or
## before the first fetch) the palette is empty and the board keeps its
## classic surface — defaults come from the server, never guessed here.
func apply_board_skin(board: Node) -> void:
	if board == null or not board.has_method("set_skin"):
		return
	board.set_skin(board_palette(equipped_key("BOARD_SKIN")))
