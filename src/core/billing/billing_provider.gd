class_name BillingProvider
extends RefCounted
## Phase 13: in-app purchase provider abstraction.
##
## The shop only ever sees these three verbs. Google Play Billing
## ships first; Apple StoreKit plugs in later by subclassing this
## and implementing the same surface. Prices always come from the
## store — nothing in this layer or the app hard-codes them.


## Whether the provider can talk to its store right now.
func is_available() -> bool:
	return false


## Asks the store for product details. Returns an Array of
## {product_id, price_text} — prices owned by the store.
func query_products(_product_ids: Array) -> Array:
	return []


## Launches the store purchase flow for one product.
## Returns {ok, purchase_token, order_id} or {ok: false, error}.
## A successful store callback is only a claim — the backend must
## verify the token before anything is granted.
func purchase(_product_id: String) -> Dictionary:
	return {"ok": false, "error": "Purchases are not supported here."}


## Products the store currently owns for this account (restore path).
## Returns an Array of {productId, purchaseToken}.
func query_owned() -> Array:
	return []
