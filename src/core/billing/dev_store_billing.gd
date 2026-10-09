class_name DevStoreBilling
extends BillingProvider
## Phase 13: development store simulator.
##
## Stands in for Google Play in dev/test: purchase tokens are minted
## by the backend's dev store (the server's stand-in for the Play
## purchase flow), exactly as Play would issue them after a real
## transaction. Prices come from the server's simulator catalog —
## this provider hard-codes none. Gated server-side; the production
## build never enables it.

var _api: ApiClient
var _auth: AuthService


func _init(api: ApiClient, auth: AuthService) -> void:
	_api = api
	_auth = auth


func is_available() -> bool:
	return _api != null and _api.is_configured()


func purchase(product_id: String) -> Dictionary:
	if not _auth.is_authenticated():
		return {"ok": false, "error": "Sign in to purchase."}
	var res: Dictionary = await _api.request_json(
			HTTPClient.METHOD_POST,
			"/shop/dev/issue",
			{"productId": product_id},
			_auth.get_access_token())
	if not res.ok:
		return {"ok": false, "error": str(res.get("message", "Store unavailable."))}
	var body: Dictionary = res.body
	var token := str(body.get("purchaseToken", ""))
	if token.is_empty():
		return {"ok": false, "error": "The store returned no purchase token."}
	return {
		"ok": true,
		"purchase_token": token,
		"order_id": str(body.get("orderId", "")),
	}


func query_owned() -> Array:
	if not _auth.is_authenticated():
		return []
	var res: Dictionary = await _auth.authenticated_get("/shop/dev/owned")
	if not res.ok:
		return []
	var items: Variant = res.body.get("items")
	return items if items is Array else []
