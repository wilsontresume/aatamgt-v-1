extends Button
## Reusable AATAMGT button with theme variants.
## Pick the visual weight via the `variant` export; all sizing/colors
## come from AppTheme.

@export_enum("Primary", "Secondary", "Ghost", "Danger") var variant: int = 0:
	set(value):
		variant = value
		if is_node_ready():
			_apply()

const VARIATIONS := ["PrimaryButton", "SecondaryButton", "GhostButton", "DangerButton"]


func _ready() -> void:
	_apply()


func set_label_text(text: String) -> void:
	self.text = text


func _apply() -> void:
	theme_type_variation = VARIATIONS[clampi(variant, 0, VARIATIONS.size() - 1)]
