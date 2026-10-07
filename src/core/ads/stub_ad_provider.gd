class_name StubAdProvider
extends AdProvider
## Phase 8 built-in provider: no ad SDK is linked yet, so a "show"
## completes immediately, deferring to the next frame like a native
## callback would. This only stands in for the provider's completion
## signal — the reward still has to survive server-side validation.

func show_rewarded(session: Dictionary) -> void:
	call_deferred("_complete_rewarded", session)


func show_interstitial(context: Dictionary) -> void:
	call_deferred("_complete_interstitial", context)


func _complete_rewarded(session: Dictionary) -> void:
	rewarded_completed.emit(session)


func _complete_interstitial(context: Dictionary) -> void:
	interstitial_completed.emit(context)
