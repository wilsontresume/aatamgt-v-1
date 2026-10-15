class_name MatchmakingService
extends RefCounted
## Multiplayer-first game entry (Workflow Change 2): tier catalog, online
## queue (pair or AI fallback), and soft player-ID lookup. Pure REST via
## AuthService — the server owns pairing, stakes and AI seats. Tier ids
## are backend-managed; the client never hard-codes a catalog.

const POLL_INTERVAL := 0.8

var _auth: AuthService


func _init(p_auth: AuthService) -> void:
	_auth = p_auth


# --- Catalog -------------------------------------------------------------

## GET /tiers → {items: [{id, label, costCoins, rewardMultiplierBp, minBalance, rewardCoins}]}
func list_tiers() -> Dictionary:
	return await _auth.authenticated_get("/tiers")


# --- Queue ---------------------------------------------------------------

## POST /matchmaking/queue {gameKey, tierId}
## → {status: queued|matched, ticketId?, matchId?, tier, vsAi?}
func queue(game_key: String, tier_id: String) -> Dictionary:
	return await _auth.authenticated_post("/matchmaking/queue",
			{"gameKey": game_key, "tierId": tier_id})


## GET /matchmaking/status → idle | queued | matched
func status() -> Dictionary:
	return await _auth.authenticated_get("/matchmaking/status")


## DELETE /matchmaking/queue → {cancelled: bool}
func cancel_queue() -> Dictionary:
	return await _auth.authenticated_delete("/matchmaking/queue")


# --- Soft player ID ------------------------------------------------------

## GET /users/lookup/:username → {id, username} or 404.
func lookup_player(username: String) -> Dictionary:
	return await _auth.authenticated_get("/users/lookup/%s" % username.strip_edges())


# --- Navigation hand-off -------------------------------------------------

var pending: Dictionary = {}


func set_pending(data: Dictionary) -> void:
	pending = data


func take_pending() -> Dictionary:
	var data := pending
	pending = {}
	return data


## Maps a main-menu carousel id to the server game key used by matchmaking.
static func game_key_for(screen_id: StringName) -> String:
	match screen_id:
		&"solah_seedi":
			return OnlineMatchService.SOLAH_SEEDI_KEY
		&"nine_mens_morris":
			return OnlineMatchService.NINE_MENS_MORRIS_KEY
		_:
			return OnlineMatchService.AADU_PULI_KEY


static func screen_for_game_key(game_key: String) -> StringName:
	return SocialService.GAME_SCREENS.get(game_key, &"")
