extends PanelContainer
## Reusable content card. Optional title / subtitle / big value / badge
## rows are shown only when set.

@export var title_text: String = "":
	set(value):
		title_text = value
		if is_node_ready():
			_refresh()

@export var subtitle_text: String = "":
	set(value):
		subtitle_text = value
		if is_node_ready():
			_refresh()

@export var value_text: String = "":
	set(value):
		value_text = value
		if is_node_ready():
			_refresh()

@export var badge_text: String = "":
	set(value):
		badge_text = value
		if is_node_ready():
			_refresh()

@onready var _title: Label = $Body/TitleLabel
@onready var _subtitle: Label = $Body/SubtitleLabel
@onready var _value: Label = $Body/ValueLabel
@onready var _badge: PanelContainer = $Body/Badge


func _ready() -> void:
	_refresh()


func _refresh() -> void:
	_title.visible = not title_text.is_empty()
	_title.text = title_text
	_subtitle.visible = not subtitle_text.is_empty()
	_subtitle.text = subtitle_text
	_value.visible = not value_text.is_empty()
	_value.text = value_text
	_badge.visible = not badge_text.is_empty()
	if not badge_text.is_empty():
		$Body/Badge/BadgeLabel.text = badge_text
