class_name CoinService
extends RefCounted
## Display-only coin balance (Phase 7: server-authoritative wallet).
##
## The balance is a projection of the server-side ledger. The ONLY
## writer is set_balance_from_server(), which is fed exclusively from
## backend payloads (GET /wallet via App.refresh_wallet, and the
## sign-out reset). The client NEVER mints, spends or validates coins —
## every grant (REGISTRATION_BONUS, DAILY_LOGIN, REWARDED_AD,
## MATCH_REWARD, ROYAL_PASS_BONUS, ADMIN_ADJUSTMENT) and every spend
## (PURCHASE, COSMETIC_PURCHASE) is decided and recorded server-side
## in the wallet transaction ledger.

signal balance_changed(current: int, previous: int)

var _balance := 0


func get_balance() -> int:
	return _balance


## Sole entry point for balance updates: a value the server reported.
## There is deliberately no add/subtract/set API on this service.
func set_balance_from_server(value: int) -> void:
	value = maxi(0, value)
	if value == _balance:
		return
	var previous := _balance
	_balance = value
	balance_changed.emit(_balance, previous)
