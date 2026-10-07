class_name AdProvider
extends RefCounted
## Phase 8 ad provider abstraction: screens and AdService present ads
## through this interface and never talk to a vendor SDK directly.
## Real SDKs (AdMob, Unity Ads, ...) subclass this and wire their
## native callbacks into the signals; StubAdProvider simulates a
## completed presentation so the full reward loop works today.

signal rewarded_completed(session: Dictionary)
signal rewarded_failed(reason: String)
signal interstitial_completed(context: Dictionary)
signal interstitial_failed(reason: String)


## Present a rewarded ad for a SERVER-MINTED session (AdService never
## hands over anything else). On completion emit rewarded_completed
## with the same session dictionary so AdService can redeem the nonce.
func show_rewarded(_session: Dictionary) -> void:
	pass


## Present an interstitial. On dismissal emit interstitial_completed
## with the context dictionary AdService passed in.
func show_interstitial(_context: Dictionary) -> void:
	pass
