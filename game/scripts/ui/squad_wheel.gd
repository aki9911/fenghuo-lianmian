extends Control
## Five persistent squad selectors; opening this overlay never pauses simulation.
signal order_requested(slot: int, order: String)
signal closed
var selected: int = 0
var title: Label
var squad_buttons: Array[Button] = []

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade = ColorRect.new()
	shade.color = Color(0.02, 0.06, 0.07, 0.68)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center = Control.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	add_child(center)
	for i in range(5):
		var angle: float = -PI / 2 + TAU * i / 5.0
		var b = Button.new()
		b.text = "%d 队" % (i + 1)
		b.position = Vector2(cos(angle), sin(angle)) * 130 - Vector2(52, 27)
		b.size = Vector2(104, 54)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(select_squad.bind(i))
		center.add_child(b)
		squad_buttons.append(b)
	title = Label.new()
	title.position = Vector2(-110, -35)
	title.size = Vector2(220, 70)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	center.add_child(title)
	var commands = HBoxContainer.new()
	commands.position = Vector2(-220, 200)
	commands.add_theme_constant_override("separation", 12)
	center.add_child(commands)
	for entry in [["跟随我", "follow"], ["原地驻守", "hold"], ["向前推进", "advance"]]:
		var b = Button.new()
		b.text = entry[0]
		b.custom_minimum_size = Vector2(140, 48)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): order_requested.emit(selected, entry[1]))
		commands.add_child(b)
	var hint = Label.new()
	hint.text = "1—5 选队  ·  点击下达指令  ·  H / Esc 返回\n战斗仍在继续；推进目标为指挥官前方 12 米"
	hint.position = Vector2(-280, 265)
	hint.size.x = 560
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(hint)
	select_squad(0)

func select_squad(index: int) -> void:
	selected = clampi(index, 0, 4)
	if title == null: return
	title.text = "第 %d 队\n选择一道军令" % (selected + 1)
	for i in range(squad_buttons.size()):
		squad_buttons[i].modulate = Color("e8c77c") if i == selected else Color.WHITE
