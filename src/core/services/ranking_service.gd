class_name RankingService
extends RefCounted
## Phase 14: competitive ranking over REST — per-game ratings, rank
## tiers, seasons, the leaderboard and rating history. The server owns
## every number; this service fetches them and mirrors the presentation
## bands so rank labels render even before a response lands.

## The three rated games — one independent rating each.
const RATED_GAME_KEYS := [
	"aadu-puli-aattam",
	"solah-seedi",
	"nine-mens-morris",
]

## Competitive display names (the 16 Soldiers alias for Solah Seedi).
const GAME_TITLES := {
	"aadu-puli-aattam": "Aadu Puli",
	"solah-seedi": "16 Soldiers",
	"nine-mens-morris": "Nine Men's Morris",
}

## Mirror of the server band table (server stays authoritative).
const RANK_TIERS := [
	{"key": "bronze", "name": "Bronze", "min": 0},
	{"key": "silver", "name": "Silver", "min": 1100},
	{"key": "gold", "name": "Gold", "min": 1300},
	{"key": "platinum", "name": "Platinum", "min": 1500},
	{"key": "diamond", "name": "Diamond", "min": 1700},
	{"key": "master", "name": "Master", "min": 1900},
]

var _auth: AuthService
var _api: ApiClient


func _init(p_auth: AuthService, p_api: ApiClient) -> void:
	_auth = p_auth
	_api = p_api


## The signed-in player's per-game rating, rank, record and position.
func summary() -> Dictionary:
	return await _auth.authenticated_get("/rankings/summary")


## Top rated competitors for one game (public endpoint).
func leaderboard(game_key: String, limit := 50) -> Dictionary:
	return await _api.request_json(HTTPClient.METHOD_GET,
			"/rankings/leaderboard?gameKey=%s&limit=%d" % [game_key, limit])


## Rating movement history for the signed-in player (win/loss + deltas).
func history(limit := 20, game_key := "") -> Dictionary:
	var path := "/rankings/history?limit=%d" % limit
	if not game_key.is_empty():
		path += "&gameKey=%s" % game_key
	return await _auth.authenticated_get(path)


## The rank tier a rating falls into (mirrors the server bands).
static func rank_of(rating: int) -> Dictionary:
	var best: Dictionary = RANK_TIERS[0]
	for tier in RANK_TIERS:
		if rating >= int(tier["min"]):
			best = tier
	return best


static func rank_title(rating: int) -> String:
	return str(rank_of(rating)["name"])
