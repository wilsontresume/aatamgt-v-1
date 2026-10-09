class_name GooglePlayBilling
extends BillingProvider
## Phase 13: Google Play Billing provider.
##
## Talks to the Android billing plugin singleton when running on a
## device that has it; price text and purchase tokens come from
## Play itself. On platforms without the plugin the provider simply
## reports unavailable and the shop shows an honest error.
##
## Bridge contract (plugin methods/signals):
##   queryProductDetails(productIds) -> signal product_details_updated(error, products)
##   makePurchase(productDetail)     -> signal purchase_updated(error, purchase)
##   queryPurchases()                -> signal purchases_updated(error, purchases)

const PLUGIN_NAME := "GodotGooglePlayBilling"
const BILLING_OK := 0
const RESPONSE_TIMEOUT_FRAMES := 600

var _billing: Object = null


func _init() -> void:
	if Engine.has_singleton(PLUGIN_NAME):
		_billing = Engine.get_singleton(PLUGIN_NAME)


func is_available() -> bool:
	return _billing != null


func query_products(product_ids: Array) -> Array:
	if _billing == null:
		return []
	var result: Array = await _call_and_await(
			&"product_details_updated", &"queryProductDetails", [product_ids])
	if int(result[0]) != BILLING_OK:
		return []
	var out := []
	for product in result[1]:
		if product is Dictionary:
			out.append({
				"product_id": str(product.get("product_id",
						product.get("productId", ""))),
				"price_text": str(product.get("price",
						product.get("price_text", ""))),
			})
	return out


func purchase(product_id: String) -> Dictionary:
	if _billing == null:
		return {"ok": false, "error": "Google Play Billing is unavailable."}
	var details: Array = await query_products([product_id])
	if details.is_empty():
		return {"ok": false,
				"error": "This product is not available from the store."}
	var result: Array = await _call_and_await(
			&"purchase_updated", &"makePurchase", [details[0]])
	if int(result[0]) != BILLING_OK:
		return {"ok": false,
				"error": "The store did not complete the purchase."}
	var purchase: Dictionary = result[1] if result[1] is Dictionary else {}
	var token := str(purchase.get("purchase_token",
			purchase.get("purchaseToken", "")))
	if token.is_empty():
		return {"ok": false,
				"error": "The store returned no purchase token."}
	return {
		"ok": true,
		"purchase_token": token,
		"order_id": str(purchase.get("order_id", purchase.get("orderId", ""))),
	}


func query_owned() -> Array:
	if _billing == null:
		return []
	var result: Array = await _call_and_await(
			&"purchases_updated", &"queryPurchases", [])
	if int(result[0]) != BILLING_OK:
		return []
	var out := []
	for purchase in result[1]:
		if purchase is Dictionary:
			out.append({
				"productId": str(purchase.get("product_id",
						purchase.get("productId", ""))),
				"purchaseToken": str(purchase.get("purchase_token",
						purchase.get("purchaseToken", ""))),
			})
	return out


## Arms a one-shot connection BEFORE invoking the plugin method (the
## response may be emitted synchronously), then yields until it
## arrives or the frame budget runs out. Returns [errorCode, payload].
func _call_and_await(signal_name: StringName, method: String,
		args: Array) -> Array:
	if _billing == null or not _billing.has_signal(signal_name):
		return [-1, []]
	var holder := {"done": false, "result": [-1, []]}
	_billing.connect(signal_name,
			func(a, b): holder.result = [a, b]; holder.done = true,
			CONNECT_ONE_SHOT)
	_billing.callv(method, args)
	var tree := Engine.get_main_loop() as SceneTree
	var frames := 0
	while not bool(holder["done"]) and frames < RESPONSE_TIMEOUT_FRAMES:
		await tree.process_frame
		frames += 1
	if not bool(holder["done"]):
		return [-1, []]
	return holder["result"]
