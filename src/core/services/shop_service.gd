class_name ShopService
extends RefCounted
## Phase 13: server-owned shop and purchase pipeline.
##
## The client never grants itself anything: `buy()` runs the store
## flow only to obtain a purchase token, then submits that token to
## the backend, which verifies it with the store and settles the
## grant. All balances and entitlements in responses come from the
## server. Prices come from the billing provider (the store), never
## from constants in this file — only the platform product IDs are
## part of the contract.

const ROYAL_PASS_KEY := "com.aatamgt.royal_pass"

const PRODUCT_KEYS := [
	"com.aatamgt.coins_100",
	"com.aatamgt.coins_1000",
	"com.aatamgt.coins_5500",
	"com.aatamgt.coins_12000",
	"com.aatamgt.coins_65000",
	"com.aatamgt.coins_150000",
	ROYAL_PASS_KEY,
]

var _api: ApiClient
var _auth: AuthService
var _coins: CoinService
var _billing: BillingProvider = null
var _catalog_items: Array = []
var _prices: Dictionary = {}
var _dev_store := false


func _init(api: ApiClient, auth: AuthService, coins: CoinService) -> void:
	_api = api
	_auth = auth
	_coins = coins


## Fetches the catalog, then asks the store for live prices.
func refresh() -> Dictionary:
	var res: Dictionary = await _api.request_json(
			HTTPClient.METHOD_GET, "/shop/products")
	if not res.ok:
		return res
	var body: Dictionary = res.body
	_dev_store = bool(body.get("devStore", false))
	var items: Variant = body.get("items")
	_catalog_items = items if items is Array else []
	_prices = {}
	# Dev store simulator: the server's fixture price list baseline.
	if _dev_store and body.get("prices") is Dictionary:
		for key in body["prices"]:
			_prices[str(key)] = str(body["prices"][key])
	# The billing provider (real Play) overrides with store prices.
	if _billing == null:
		_billing = DevStoreBilling.new(_api, _auth) if _dev_store \
				else GooglePlayBilling.new()
	if _billing.is_available():
		var ids := []
		for item in _catalog_items:
			ids.append(str((item as Dictionary).get("productKey", "")))
		var store_details: Array = await _billing.query_products(ids)
		for entry in store_details:
			if entry is Dictionary:
				var price := str(entry.get("price_text", ""))
				if not price.is_empty():
					_prices[str(entry.get("product_id", ""))] = price
	return res


func is_loaded() -> bool:
	return not _catalog_items.is_empty()


func dev_store_enabled() -> bool:
	return _dev_store


## Catalog rows enriched with the store's price text.
func products() -> Array:
	var out := []
	for item in _catalog_items:
		if item is Dictionary:
			var copy: Dictionary = (item as Dictionary).duplicate()
			copy["price_text"] = price_text(str(copy.get("productKey", "")))
			out.append(copy)
	return out


func price_text(product_key: String) -> String:
	return str(_prices.get(product_key, ""))


## Store flow → server verification → server grant. `result` in the
## success shape is the backend's response, untouched.
func buy(product_key: String) -> Dictionary:
	if not _auth.is_authenticated():
		return _fail("Sign in to purchase.")
	if _billing == null or not _billing.is_available():
		return _fail("The store is unavailable right now.")
	var token: Dictionary = await _billing.purchase(product_key)
	if not token.get("ok", false):
		return _fail(str(token.get("error", "The store cancelled the purchase.")))
	var res: Dictionary = await _auth.authenticated_post("/purchases", {
		"productId": product_key,
		"purchaseToken": str(token.get("purchase_token", "")),
	})
	if not res.ok:
		return _fail(str(res.get("message", "Purchase verification failed.")), "verify")
	var body: Dictionary = res.body
	var status := str(body.get("status", ""))
	if status == "granted" or status == "already_processed":
		_apply_balance(body)
		return {"ok": true, "status": status, "result": body}
	if status == "pending":
		return {"ok": true, "status": "pending", "result": body}
	return _fail("The store reported this purchase as '%s'." % status, "verify")


## Restore: asks the store what it owns, then has the server
## re-verify and settle every token (idempotent).
func restore() -> Dictionary:
	if not _auth.is_authenticated():
		return _fail("Sign in to restore purchases.")
	if _billing == null or not _billing.is_available():
		return _fail("The store is unavailable right now.")
	var owned: Array = await _billing.query_owned()
	var items := []
	for entry in owned:
		if entry is Dictionary:
			items.append({
				"productId": str(entry.get("productId", "")),
				"purchaseToken": str(entry.get("purchaseToken", "")),
			})
	if items.is_empty():
		# Nothing from the store: still let the server settle state.
		var ent: Dictionary = await entitlement()
		return {"ok": true, "restored": 0, "results": [],
				"royalPass": ent.body if ent.ok else {}}
	var res: Dictionary = await _auth.authenticated_post(
			"/purchases/restore", {"items": items})
	if not res.ok:
		return _fail(str(res.get("message", "Restore failed.")), "verify")
	var body: Dictionary = res.body
	_apply_balance(body)
	var results: Array = body.get("results") if body.get("results") is Array else []
	var restored := 0
	for entry in results:
		if entry is Dictionary and str(entry.get("status", "")) == "granted":
			restored += 1
	return {"ok": true, "restored": restored, "results": results,
			"royalPass": body.get("royalPass", {})}


## Server-side Royal Pass entitlement state.
func entitlement() -> Dictionary:
	return await _auth.authenticated_get("/shop/entitlements")


## Server-side purchase history for this account.
func history() -> Dictionary:
	return await _auth.authenticated_get("/purchases")


func _apply_balance(body: Dictionary) -> void:
	if body.has("coinsBalance"):
		_coins.set_balance_from_server(int(body.get("coinsBalance", 0)))


func _fail(message: String, stage := "store") -> Dictionary:
	return {"ok": false, "error": message, "stage": stage}
