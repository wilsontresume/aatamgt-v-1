extends VBoxContainer
## Loading overlay content: spinner + caption. Shown/hidden by DialogService.


func set_text(text: String) -> void:
	if has_node("TextLabel"):
		$TextLabel.text = text
