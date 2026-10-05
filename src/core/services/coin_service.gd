class_name CoinService
extends RefCounted
## Placeholder coin balance service (Phase 1 — display only).
##
## Phase 2+: the balance is a projection of the server-side ledger.
## The client NEVER mints, spends or validates coins; it only reflects
## values delivered by the authoritative backend.

signal balance_changed(current: int, previous: int)

var _balance := 0


func get_balance() -> int:
	return _balance


## Entry point for server-delivered balances (Phase 2).
## In Phase 1 nothing calls this, so the UI honestly shows 0.
func set_balance_from_server(value: int) -> void:
	value = maxi(0, value)
	if value == _balance:
		return
	var previous := _balance
	_balance = value
	balance_changed.emit(_balance, previous)


# Phase 2 TODO: subscribe to wallet updates over WebSocket, and reconcile
# after reconnect using the backend wallet endpoint.
