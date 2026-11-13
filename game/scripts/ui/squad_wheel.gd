extends Control
## Five persistent squad selectors; opening this overlay never pauses simulation.
signal order_requested(slot: int, order: String)
signal army_order_requested(order: String)
signal closed
var selected: int = 0
var title: Label
var squad_buttons: Array[Button] = []
var command_buttons: Array[Button] = []
var army_hold_button: Button
var army_resume_button: Button
var army_holding: bool = false

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
	for entry in [["跟随我", "follow"], ["守卫阵位", "guard"], ["向前推进", "advance"]]:
		var b = Button.new()
		b.text = entry[0]
		b.custom_minimum_size = Vector2(140, 48)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): order_requested.emit(selected, entry[1]))
		commands.add_child(b)
		command_buttons.append(b)
	var army_commands = HBoxContainer.new()
	army_commands.position = Vector2(-220, 260)
	army_commands.add_theme_constant_override("separation", 12)
	center.add_child(army_commands)
	army_hold_button = Button.new()
	army_hold_button.text = "全军固守"
	army_hold_button.custom_minimum_size = Vector2(216, 48)
	army_hold_button.focus_mode = Control.FOCUS_NONE
	army_hold_button.pressed.connect(func(): army_order_requested.emit("hold"))
	army_commands.add_child(army_hold_button)
	army_resume_button = Button.new()
	army_resume_button.text = "全军恢复行动"
	army_resume_button.custom_minimum_size = Vector2(216, 48)
	army_resume_button.focus_mode = Control.FOCUS_NONE
	army_resume_button.pressed.connect(func(): army_order_requested.emit("guard"))
	army_commands.add_child(army_resume_button)
	var hint = Label.new()
	hint.text = "默认有限追击；全军固守会停止移动，也会阻止军队撤离\n1—5 选队  ·  H / Esc 返回  ·  轮盘不暂停战斗"
	hint.position = Vector2(-320, 322)
	hint.size.x = 640
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(hint)
	select_squad(0)
	set_army_holding(false)

func set_army_holding(enabled: bool) -> void:
	army_holding = enabled
	if army_hold_button == null: return
	army_hold_button.disabled = enabled
	army_resume_button.disabled = not enabled
	for b in command_buttons: b.disabled = enabled
	select_squad(selected)

func select_squad(index: int) -> void:
	selected = clampi(index, 0, 4)
	if title == null: return
	title.text = "全军固守中\n先恢复行动" if army_holding else "第 %d 队\n选择一道军令" % (selected + 1)
	for i in range(squad_buttons.size()):
		squad_buttons[i].modulate = Color("e8c77c") if i == selected else Color.WHITE
