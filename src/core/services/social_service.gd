class_name SocialService
extends RefCounted
## Phase 11: friends, challenges and match history over plain REST.
##
## Social flow adds no socket events: screens call these helpers and
## render the returned dictionaries. The share text for WhatsApp
## challenges is composed here (statically) so every surface — and the
## test suite — builds the exact same message.

## Navigation hand-off: set before App.navigation.go(&"challenge"),
## consumed by the challenge screen in _ready().
var pending: Dictionary = {}

const GAME_TITLES := {
	"aadu-puli-aattam": "Aadu Puli Aattam",
	"solah-seedi": "Solah Seedi",
	"nine-mens-morris": "Nine Men's Morris",
}
const GAME_SCREENS := {
	"aadu-puli-aattam": &"aadu_puli",
	"solah-seedi": &"solah_seedi",
	"nine-mens-morris": &"nine_mens_morris",
}

var _auth: AuthService


func _init(p_auth: AuthService) -> void:
	_auth = p_auth


# --- Friend list ----------------------------------------------------------

## GET /friends → {friends, incoming, outgoing, blocked}.
func list_friends() -> Dictionary:
	return await _auth.authenticated_get("/friends")


func send_friend_request(username: String) -> Dictionary:
	return await _auth.authenticated_post("/friends/requests",
			{"username": username})


func accept_friend_request(friendship_id: String) -> Dictionary:
	return await _auth.authenticated_post(
			"/friends/requests/%s/accept" % friendship_id, {})


func decline_friend_request(friendship_id: String) -> Dictionary:
	return await _auth.authenticated_post(
			"/friends/requests/%s/decline" % friendship_id, {})


## Also used to unblock: the server deletes the BLOCKED row.
func remove_friend(friendship_id: String) -> Dictionary:
	return await _auth.authenticated_delete("/friends/%s" % friendship_id)


func block_user(username: String) -> Dictionary:
	return await _auth.authenticated_post("/friends/block", {"username": username})


# --- Challenges -----------------------------------------------------------

## POST /challenges {gameKey, inviteeUsername?} → serialized challenge.
func create_challenge(game_key: String, invitee_username: String = "") -> Dictionary:
	var body := {"gameKey": game_key}
	if not invitee_username.is_empty():
		body["inviteeUsername"] = invitee_username
	return await _auth.authenticated_post("/challenges", body)


func get_challenge(code: String) -> Dictionary:
	return await _auth.authenticated_get("/challenges/%s" % code.strip_edges().to_upper())


func accept_challenge(code: String) -> Dictionary:
	return await _auth.authenticated_post(
			"/challenges/%s/accept" % code.strip_edges().to_upper(), {})


func decline_challenge(code: String) -> Dictionary:
	return await _auth.authenticated_post(
			"/challenges/%s/decline" % code.strip_edges().to_upper(), {})


func cancel_challenge(code: String) -> Dictionary:
	return await _auth.authenticated_post(
			"/challenges/%s/cancel" % code.strip_edges().to_upper(), {})


## GET /challenges → {incoming, outgoing} of PENDING challenges.
func challenge_inbox() -> Dictionary:
	return await _auth.authenticated_get("/challenges")


# --- History --------------------------------------------------------------

## GET /matches?status=COMPLETED → {items} newest first.
func match_history() -> Dictionary:
	return await _auth.authenticated_get("/matches?status=COMPLETED")


# --- Navigation hand-off --------------------------------------------------

func set_pending(data: Dictionary) -> void:
	pending = data


func take_pending() -> Dictionary:
	var data := pending
	pending = {}
	return data


# --- Static helpers (pure — unit-testable offline) -------------------------

static func game_title(game_key: String) -> String:
	return str(GAME_TITLES.get(game_key, game_key))


static func screen_for(game_key: String) -> StringName:
	return GAME_SCREENS.get(game_key, &"")


## The WhatsApp share text. First three lines match the product example:
##   AATAMGT challenge:
##   Wilson challenged you to Aadu Puli Aattam.
##   Join the match.
## The code line is appended so the recipient can enter it in-app.
static func challenge_message(challenger_name: String, game_name: String,
		code: String, link_base: String = "") -> String:
	var text := "AATAMGT challenge:\n%s challenged you to %s.\nJoin the match." \
			% [challenger_name, game_name]
	text += "\n\nCode: %s" % code.strip_edges().to_upper()
	if not link_base.is_empty():
		var sep := "&" if link_base.contains("?") else "?"
		text += "\n%s%schallenge=%s" % [link_base, sep, code.strip_edges().to_upper()]
	return text


## WhatsApp is targeted through wa.me (reliable everywhere; the native
## scheme is not detectable from Godot).
static func whatsapp_url(message: String) -> String:
	return "https://wa.me/?text=%s" % message.uri_encode()


static func is_valid_code(code: String) -> bool:
	var normalized := code.strip_edges().to_upper()
	if normalized.length() < 4 or normalized.length() > 16:
		return false
	for i in normalized.length():
		var ch := normalized.unicode_at(i)
		var is_digit := ch >= 48 and ch <= 57
		var is_upper := ch >= 65 and ch <= 90
		if not (is_digit or is_upper):
			return false
	return true
