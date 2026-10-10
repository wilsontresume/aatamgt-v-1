class_name AdminService
extends RefCounted
## Phase 15: the admin dashboard's read/write surface. Every call is a
## thin, pass-through wrapper over the existing AdminController REST
## endpoints — the server enforces roles, validates payloads and writes
## the audit trail; nothing here derives or mutates platform state.
##
## Reads require MODERATOR or ADMIN, mutations require ADMIN — a
## non-staff session receives 403 from the server regardless of what
## this client does, and the dashboard screen hides itself anyway.

var _auth: AuthService


func _init(p_auth: AuthService) -> void:
	_auth = p_auth


# --- Overview / Players -------------------------------------------------

## Platform-wide counters for the dashboard header.
func stats() -> Dictionary:
	return await _auth.authenticated_get("/admin/stats")


## Paginated player search (username/email substring).
func players(q := "", page := 1, limit := 20) -> Dictionary:
	var path := "/admin/users?page=%d&limit=%d" % [page, limit]
	if not q.is_empty():
		path += "&q=%s" % q.uri_encode()
	return await _auth.authenticated_get(path)


## One player's identity, profile stats and wallet balances.
func player(player_id: String) -> Dictionary:
	return await _auth.authenticated_get("/admin/users/%s" % player_id)


## Balance plus the paginated transaction ledger for one player.
func player_wallet(player_id: String, page := 1, limit := 20) -> Dictionary:
	return await _auth.authenticated_get(
			"/admin/users/%s/wallet?page=%d&limit=%d" % [player_id, page, limit])


## Match history for one player.
func player_matches(player_id: String, page := 1, limit := 20) -> Dictionary:
	return await _auth.authenticated_get(
			"/admin/users/%s/matches?page=%d&limit=%d" % [player_id, page, limit])


## ACTIVE / SUSPENDED / BANNED with an optional audit reason.
func set_status(player_id: String, status: String, reason := "") -> Dictionary:
	var payload := {"status": status}
	if not reason.is_empty():
		payload["reason"] = reason
	return await _auth.authenticated_patch(
			"/admin/users/%s/status" % player_id, payload)


# --- Games ---------------------------------------------------------------

## All matches, optionally filtered by status
## (PENDING/ACTIVE/PAUSED/COMPLETED/ABANDONED/CANCELLED).
func matches(status := "", page := 1, limit := 20) -> Dictionary:
	var path := "/admin/matches?page=%d&limit=%d" % [page, limit]
	if not status.is_empty():
		path += "&status=%s" % status
	return await _auth.authenticated_get(path)


## Operator-driven finalisation with explicit player results.
func finalize_match(match_id: String, status: String, players: Array,
		reason := "") -> Dictionary:
	var payload := {"status": status, "players": players}
	if not reason.is_empty():
		payload["reason"] = reason
	return await _auth.authenticated_patch(
			"/admin/matches/%s/finalize" % match_id, payload)


# --- Economy -------------------------------------------------------------

## Coins issued/spent, transaction counts, rewarded ads and purchases.
func economy_summary() -> Dictionary:
	return await _auth.authenticated_get("/admin/economy/summary")


## Global (or per-player) transaction ledger with optional type filter.
func transactions(user_id := "", tx_type := "", page := 1, limit := 20) -> Dictionary:
	var path := "/admin/economy/transactions?page=%d&limit=%d" % [page, limit]
	if not user_id.is_empty():
		path += "&userId=%s" % user_id.uri_encode()
	if not tx_type.is_empty():
		path += "&type=%s" % tx_type
	return await _auth.authenticated_get(path)


## Recent interstitial/rewarded ad presentations.
func ad_shows(page := 1, limit := 20) -> Dictionary:
	return await _auth.authenticated_get(
			"/admin/economy/ads?page=%d&limit=%d" % [page, limit])


## Store purchases with usernames and grant states.
func purchases(page := 1, limit := 20) -> Dictionary:
	return await _auth.authenticated_get(
			"/admin/economy/purchases?page=%d&limit=%d" % [page, limit])


# --- Content -------------------------------------------------------------

## Full cosmetic catalog (admin view: inactive rows included).
func cosmetics(category := "", page := 1, limit := 50) -> Dictionary:
	var path := "/admin/cosmetics?page=%d&limit=%d" % [page, limit]
	if not category.is_empty():
		path += "&category=%s" % category
	return await _auth.authenticated_get(path)


## Price / name / active toggles. Patch keys left out stay unchanged.
func update_cosmetic(cosmetic_id: String, patch: Dictionary) -> Dictionary:
	return await _auth.authenticated_patch(
			"/admin/cosmetics/%s" % cosmetic_id, patch)


# --- Configuration -------------------------------------------------------

## Every config key with its live value, default and bounds.
func config_entries() -> Dictionary:
	return await _auth.authenticated_get("/admin/config")


## Batched override save: entries = [{key, value}, ...].
func save_config(entries: Array) -> Dictionary:
	return await _auth.authenticated_put("/admin/config", {"entries": entries})


# --- Audit ---------------------------------------------------------------

## The immutable admin action log (actor, action, target, data).
func audit_log(page := 1, limit := 20) -> Dictionary:
	return await _auth.authenticated_get(
			"/admin/audit?page=%d&limit=%d" % [page, limit])
