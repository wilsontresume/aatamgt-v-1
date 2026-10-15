class_name RewardsService
extends RefCounted
## Daily login rewards — thin client over the backend's existing
## `/rewards/daily` surface. The server owns streaks, amounts and
## idempotency; this service never grants or mutates balances locally.
##
## Status shape (GET /rewards/daily):
##   {todayClaimed: bool, currentStreak: int, nextRewardCoins: int, nextStreakDay: int}
## Claim shape (POST /rewards/daily/claim):
##   {claimedAt: String, coins: int, streakDay: int, balance: int}

var _auth: AuthService


func _init(auth: AuthService) -> void:
	_auth = auth


## Server-side claim status for the signed-in user. Fails soft with the
## standard {ok=false, error, error_kind} envelope when signed out or
## offline — callers must handle that (never fake a claimable state).
func daily_status() -> Dictionary:
	return await _auth.authenticated_get("/rewards/daily")


## Claims today's reward. On success the caller re-reads the wallet via
## App.refresh_wallet() — this service never touches CoinService.
func claim_daily() -> Dictionary:
	return await _auth.authenticated_post("/rewards/daily/claim", {})
