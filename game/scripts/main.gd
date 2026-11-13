extends Node
## Composition root: UI and inputs only; rules belong to the two core models.
const Town = preload("res://scripts/core/town_state.gd")
const Battle = preload("res://scripts/core/battle_model.gd")

const INK = Color("132025")
const PAPER = Color("e5dfcf")
const MUTED = Color("91a39e")
const GOLD = Color("d9b873")
const TEAL = Color("7cc7bc")
const ROLES = {"unhired":"自由居民", "engineer":"工程兵", "medical":"医疗队伍", "supply":"军需制作", "reserve":"防御预备队"}
const ITEMS = {"material":"木石", "herb_raw":"生草药", "food_raw":"食材", "equipment":"装备", "medicine":"药品", "siege_engine":"器械", "rations":"军粮"}
const PHASES = ["城外 · 突袭", "木墙 · 防御", "城内 · 巷战", "小门 · 撤离"]
const JOBS = {"gather_material":"采集木石", "gather_herb":"采集草药", "gather_food":"采集食材", "craft_equipment":"制作装备", "prepare_medicine":"整理药品", "craft_engine":"制作器械", "cook_rations":"制作军粮", "repair_outer":"修缮城外与木墙", "repair_street":"修缮街区", "repair_evac":"修缮疏散门", "heal_wounded":"救治伤员", "salvage_field":"打扫战场"}
var config: Dictionary
var town
var battle
var world
var operating: bool = true
var town_pos = Vector2(0, 12)
var walk_target = Vector2.INF
var interface_mode: String = "field"
var sidebar_panel: PanelContainer
var primary_action: Button
var battle_guide: PanelContainer
var battle_guide_text: Label
var wheel: Control
var crosshair: Label
var interaction_hint: Label
var selected_role: String = "engineer"
var formation_slot: int = 0
var root: Control
var sidebar: VBoxContainer
var viewport: SubViewport
var viewport_container: SubViewportContainer
var labels: Dictionary = {}
var bars: Dictionary = {}
var resource_label: Label
var state_label: Label
var objective_label: Label
var notice_label: Label
var roster_label: Label
var phase_label: Label
var help_label: Label
var hire_button: Button
var notice_time: float = 0.0
var ui_clock: float = 0.0
var seen_phase: int = -1
var seen_mode: String = ""
var reports: Array = []
var recorded: bool = false
var dev_open: bool = false
var total_merit: int = 0
var run_counter: int = 0
var qa_enabled: bool = false
var qa_time: float = 0.0
var qa_step: int = 0
var qa_samples: Array = []
var qa_max_enemies: int = 0
var qa_max_allies: int = 0
var escape_confirm_until: float = 0.0
var used_dev_tools: bool = false

func _ready() -> void:
	Engine.max_fps = 60
	var file = FileAccess.open("res://data/runtime_config.json", FileAccess.READ)
	if file == null:
		push_error("缺少运行配置，请先运行 tools/export_config.py --prototype")
		get_tree().quit(1)
		return
	config = JSON.parse_string(file.get_as_text())
	town = Town.new()
	town.setup(config)
	battle = Battle.new()
	battle.setup(town, config)
	_build_ui()
	_build_sidebar()
	_refresh_ui()
	qa_enabled = "--qa" in OS.get_cmdline_user_args()
	world.warp_player(town_pos)
	_set_interface("field")
	toast("WASD 行走，鼠标转向；靠近建筑按 E。M 查看全镇，指挥所接敌。")

func style(bg: Color, border: Color = Color.TRANSPARENT, radius: int = 8) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1 if border.a > 0 else 0)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 9
	s.content_margin_bottom = 9
	return s

func text_node(parent: Node, content: String, size: int = 16, color: Color = PAPER) -> Label:
	var node = Label.new()
	node.text = content
	node.add_theme_color_override("font_color", color)
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_shadow_color", Color(0,0,0,0.95))
	node.add_theme_constant_override("shadow_offset_x", 1)
	node.add_theme_constant_override("shadow_offset_y", 2)
	parent.add_child(node)
	return node

func paragraph(parent: Node, content: String, size: int = 14, color: Color = MUTED) -> Label:
	var node = text_node(parent, content, size, color)
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return node

func button(parent: Node, title: String, action: Callable, accent: bool = false) -> Button:
	var b = Button.new()
	b.text = title
	b.custom_minimum_size.y = 40
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_stylebox_override("normal", style(Color("385c57") if accent else Color("26363a"), Color("789c7d") if accent else Color("3a4b4c")))
	b.add_theme_stylebox_override("hover", style(Color("42635b"), GOLD))
	b.add_theme_stylebox_override("pressed", style(Color("536c58"), GOLD))
	b.add_theme_stylebox_override("disabled", style(Color("202d31")))
	b.add_theme_color_override("font_color", PAPER)
	b.add_theme_color_override("font_disabled_color", Color("667572"))
	b.add_theme_font_size_override("font_size", 15)
	b.pressed.connect(action)
	b.focus_mode = Control.FOCUS_NONE
	parent.add_child(b)
	return b

func rule(parent: Node) -> void:
	var sep = HSeparator.new()
	sep.add_theme_constant_override("separation", 14)
	parent.add_child(sep)

func row(parent: Node) -> HBoxContainer:
	var node = HBoxContainer.new()
	node.add_theme_constant_override("separation", 8)
	parent.add_child(node)
	return node

func meter(parent: Node, id: String, caption: String, color: Color = TEAL) -> void:
	labels[id] = text_node(parent, caption, 14)
	var bar = ProgressBar.new()
	bar.custom_minimum_size.y = 6
	bar.show_percentage = false
	bar.add_theme_stylebox_override("background", style(Color("2b3c3d"), Color.TRANSPARENT, 3))
	bar.add_theme_stylebox_override("fill", style(color, Color.TRANSPARENT, 3))
	parent.add_child(bar)
	bars[id] = bar

func _build_ui() -> void:
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var font = FontVariation.new()
	font.base_font = preload("res://assets/fonts/NotoSansSC.ttf")
	font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 500}
	var theme = Theme.new()
	theme.default_font = font
	theme.default_font_size = 15
	root.theme = theme
	viewport_container = SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(viewport_container)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1440, 864)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.handle_input_locally = false
	viewport_container.add_child(viewport)
	world = get_node("World")
	world.reparent(viewport, false)
	world.setup()
	for label in world.labels: label.font = font
	viewport_container.gui_input.connect(_map_input)
	var top = VBoxContainer.new()
	top.position = Vector2(24, 18)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	state_label = text_node(top, "烽火连绵", 24, GOLD)
	phase_label = text_node(top, "", 16, PAPER)
	roster_label = text_node(top, "", 14, PAPER)
	resource_label = text_node(top, "", 13, GOLD)
	battle_guide = PanelContainer.new()
	battle_guide.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	battle_guide.offset_left = -400
	battle_guide.offset_right = -20
	battle_guide.offset_top = 24
	battle_guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	battle_guide.add_theme_stylebox_override("panel", style(Color(0.07, 0.12, 0.14, 0.95), GOLD))
	root.add_child(battle_guide)
	var guide_content = VBoxContainer.new()
	guide_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	battle_guide.add_child(guide_content)
	text_node(guide_content, "迎敌指引", 22, GOLD).mouse_filter = Control.MOUSE_FILTER_IGNORE
	battle_guide_text = paragraph(guide_content, "", 17, PAPER)
	battle_guide_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sidebar_panel = PanelContainer.new()
	sidebar_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	sidebar_panel.offset_left = -400
	sidebar_panel.offset_right = -20
	sidebar_panel.offset_top = 110
	sidebar_panel.offset_bottom = -110
	sidebar_panel.add_theme_stylebox_override("panel", style(Color(0.07, 0.12, 0.14, 0.96), Color("445d58")))
	root.add_child(sidebar_panel)
	var sidebar_layout = VBoxContainer.new()
	sidebar_layout.add_theme_constant_override("separation", 12)
	sidebar_panel.add_child(sidebar_layout)
	primary_action = button(sidebar_layout, "", _primary_action, true)
	primary_action.custom_minimum_size.y = 54
	primary_action.add_theme_font_size_override("font_size", 18)
	primary_action.hide()
	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sidebar_layout.add_child(scroll)
	sidebar = VBoxContainer.new()
	sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar.add_theme_constant_override("separation", 9)
	scroll.add_child(sidebar)
	var bottom = VBoxContainer.new()
	bottom.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 24
	bottom.offset_right = -430
	bottom.offset_top = -152
	bottom.offset_bottom = -15
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	interaction_hint = text_node(bottom, "", 21, GOLD)
	objective_label = paragraph(bottom, "", 14, PAPER)
	notice_label = paragraph(bottom, "", 14, GOLD)
	help_label = text_node(bottom, "WASD 移动 · 鼠标转向 · E 交互 · M 总览 · H 军令 · Esc 鼠标", 13, PAPER)
	crosshair = Label.new()
	crosshair.text = "+"
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	crosshair.position -= Vector2(5, 12)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(crosshair)
	wheel = preload("res://scripts/ui/squad_wheel.gd").new()
	root.add_child(wheel)
	wheel.order_requested.connect(_issue_order)
	wheel.army_order_requested.connect(_issue_army_order)
	wheel.closed.connect(func(): _set_interface("field"))
	wheel.hide()
	for node in top.get_children() + bottom.get_children(): node.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _set_interface(mode: String) -> void:
	interface_mode = mode
	world.set_tactical(mode in ["map", "command"])
	sidebar_panel.visible = mode in ["map", "building", "command", "report"]
	resource_label.visible = sidebar_panel.visible
	wheel.visible = mode == "wheel"
	crosshair.visible = mode == "field"
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mode == "field" and not OS.has_feature("web") else Input.MOUSE_MODE_VISIBLE
	_build_sidebar()
	_refresh_ui()

func _build_sidebar() -> void:
	for child in sidebar.get_children():
		sidebar.remove_child(child)
		child.queue_free()
	labels.clear()
	bars.clear()
	hire_button = null
	primary_action.visible = (operating and interface_mode == "building" and selected_role == "headquarters") or (not operating and interface_mode == "command" and battle.mode == "deploy")
	primary_action.text = "迎战来敌  →  暂停布阵" if operating else "确认布阵 · 开始交战"
	if interface_mode == "report":
		_build_report()
	elif interface_mode == "map":
		_build_overview()
	elif interface_mode == "command":
		_build_battle()
	elif interface_mode == "building":
		_build_operations()
	if sidebar_panel.visible and interface_mode != "report":
		rule(sidebar)
		button(sidebar, "返回行走（Esc）", func(): _set_interface("field"))
	if dev_open and sidebar_panel.visible:
		rule(sidebar)
		text_node(sidebar, "开发测试（不计入正式评价）", 14, GOLD)
		if not operating and battle.mode != "result":
			button(sidebar, "测试：推进下一阶段", func(): used_dev_tools = true; battle.advance_phase())
			button(sidebar, "测试：敌军士气归零", func(): used_dev_tools = true; battle.debug_set_morale(0))
		button(sidebar, "重置完整演示", _reset_demo)

func _build_overview() -> void:
	text_node(sidebar, "望烽镇 · 总览", 23, GOLD)
	paragraph(sidebar, "选择建筑查看位置，走近入口按 E 办理镇务。M 返回第三人称。", 15, PAPER)
	button(sidebar, "指挥所 · 迎敌 / 布阵", _visit_building.bind("headquarters"), true)
	labels.population = paragraph(sidebar, "", 14)
	for building in world.get_building_definitions():
		if building.id == "headquarters": continue
		button(sidebar, building.name, _visit_building.bind(building.id))
	if operating:
		for id in ["outer", "street", "evac"]: meter(sidebar, id, id)
		var saves = row(sidebar)
		button(saves, "保存镇务", _save)
		button(saves, "读取镇务", _load_save)
	else:
		meter(sidebar, "morale", "敌军士气", Color("c37d60"))
		labels.battle_info = paragraph(sidebar, "", 13)
		paragraph(sidebar, "部署需到指挥所；实时战斗按 H 发出分队军令。")

func _build_operations() -> void:
	if selected_role == "headquarters":
		text_node(sidebar, "指挥所", 22, GOLD)
		labels.population = paragraph(sidebar, "", 14, PAPER)
		button(sidebar, "分发装备", _equip)
		paragraph(sidebar, "在此接敌后打开战场布阵。阶段之间暂停；到指挥所重新部署。")
		return
	text_node(sidebar, ROLES[selected_role], 22, GOLD)
	labels.workers = text_node(sidebar, "", 14)
	labels.hiring = paragraph(sidebar, "", 13)
	var hire_row = row(sidebar)
	hire_button = button(hire_row, "雇佣 5 人", _hire, true)
	button(hire_row, "遣散 5 人", _dismiss)
	if selected_role != "reserve":
		var select = OptionButton.new()
		select.custom_minimum_size.y = 38
		select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ids: Array = []
		for job_id in config.jobs:
			if config.jobs[job_id].team_id == selected_role:
				ids.append(job_id)
				select.add_item(JOBS.get(job_id, job_id))
		select.select(maxi(0, ids.find(town.jobs.get(selected_role, ""))))
		select.item_selected.connect(func(i): _assign_job(selected_role, ids[i]))
		sidebar.add_child(select)
		meter(sidebar, "job", "作业进度")
		labels.job_status = paragraph(sidebar, "", 13)
	else:
		paragraph(sidebar, "预备队来自现有居民。布阵时可转入阵亡造成的军队空缺；伤员仍占编制。")
	text_node(sidebar, "自由居民采集", 14, MUTED)
	var gather = row(sidebar)
	button(gather, "木石", func(): _assign_job("unhired", "gather_material"))
	button(gather, "草药", func(): _assign_job("unhired", "gather_herb"))
	button(gather, "食材", func(): _assign_job("unhired", "gather_food"))
	labels.gather = paragraph(sidebar, "", 12)
	rule(sidebar)
	meter(sidebar, "outer", "木墙", GOLD)
	meter(sidebar, "street", "街区")
	meter(sidebar, "evac", "疏散门")
	if selected_role == "supply":
		button(sidebar, "支援邻镇：10 木石", _send_support)
		labels.transport = paragraph(sidebar, "", 12)

func _build_battle() -> void:
	text_node(sidebar, PHASES[battle.phase], 22, GOLD)
	text_node(sidebar, "暂停布阵" if battle.mode == "deploy" else "实时交战", 16, TEAL)
	meter(sidebar, "morale", "敌军士气", Color("c37d60"))
	meter(sidebar, "health", "指挥官", TEAL)
	labels.army = paragraph(sidebar, "", 14, PAPER)
	if battle.mode == "deploy":
		paragraph(sidebar, "NPC 与生产暂停，玩家可行走。选队后左键合法地面，队伍立即改位。")
		var formation = row(sidebar)
		for i in range(5):
			button(formation, str(i + 1), _select_formation.bind(i), i == formation_slot)
		labels.formation = paragraph(sidebar, "", 13)
		var deploy_row = row(sidebar)
		button(deploy_row, "分发装备", _equip)
		button(deploy_row, "预备队补员", _reinforce)
		button(sidebar, "布置床弩（消耗 1 器械）", _deploy_ballista)
		paragraph(sidebar, "军粮支持本场出战；修好的木墙、街区和小门将直接改变防守与撤离能力。", 13)
	else:
		if battle.phase == 0:
			meter(sidebar, "supply", "敌军粮草", GOLD)
			bars.supply.max_value = float(config.combat.get("supply_hp", 120))
			paragraph(sidebar, "靠近粮草仓按 E 破坏，每场固定扣除 30 点士气。按 Q 撤回木墙。", 14)
			button(sidebar, "撤回木墙", func(): battle.retreat())
		elif battle.phase == 1:
			meter(sidebar, "gate", "主城门耐久", GOLD)
			bars.gate.max_value = float(config.combat.get("gate_base_hp", 800))
			paragraph(sidebar, "消耗敌军士气守住城镇。靠近墙后的床弩按 E 射击；城门失守自动进入巷战。")
		elif battle.phase == 2:
			for i in range(3):
				meter(sidebar, "point" + str(i), ["西街", "主街", "东街"][i] + "敌军占领", Color("bd8063"))
			paragraph(sidebar, "我军可夺回街区。三个点同时失守才转入撤离。")
		else:
			meter(sidebar, "evac_count", "撤离进度", GOLD)
			paragraph(sidebar, "护送居民到东南小门。士气归零只会停止追击；镇已失守。队列通过后到小门按 E 撤出。")
		button(sidebar, "近战挥击（空格）", _attack_nearest)
		button(sidebar, "执行附近交互（E）", _interact)
	rule(sidebar)
	labels.battle_info = paragraph(sidebar, "", 13)

func _build_report() -> void:
	var report: Dictionary = battle.report
	text_node(sidebar, "战地军报", 22, GOLD)
	text_node(sidebar, str(report.get("result", "战斗结束")), 26, TEAL if report.get("town_held", false) else Color("dda47e"))
	paragraph(sidebar, "望烽镇仍在我方手中。可派工程兵清扫战场，医疗队救治伤员。" if report.get("town_held", false) else "城镇失守。按实际通过小门的人口结算，本地演示可重新建立试验镇。", 15, PAPER)
	rule(sidebar)
	for entry in [["击败敌军", "kills"], ["撤出军民", "escaped"], ["其中原居民", "civilian_escaped"], ["牺牲", "dead"], ["伤员", "wounded"], ["失踪 / 未撤出", "missing"], ["已投入敌军残余", "remaining_enemies"], ["本场功勋", "merit"]]:
		text_node(sidebar, entry[0] + "    " + str(report.get(entry[1], 0)), 16)
	paragraph(sidebar, "开战人口基准：%d 人\n累计本地功勋：%d\n本机战报：%d 场" % [report.get("baseline", 150), total_merit, reports.size()], 14)
	rule(sidebar)
	paragraph(sidebar, "战区统计和玩家排名尚未联网。本页仅记录本机战果；政府支援留待后续开发。", 13)
	if report.get("town_held", false):
		button(sidebar, "返回镇务 · 救治与修缮", _return_town, true)
	else:
		button(sidebar, "建立新的试验镇", _reset_demo, true)

func _physics_process(delta: float) -> void:
	if town == null or world == null: return
	if operating:
		town.tick(delta)
		_move_player(delta)
		world.sync_town(town_pos, delta)
	else:
		_sync_phase()
		if battle.mode in ["combat", "deploy"]: _move_player(delta)
		battle.player_facing = world.player_facing()
		battle.tick(delta)
		_sync_phase()
		world.sync_battle(battle, delta)
	if interface_mode in ["building", "command"] and not _near_building():
		_set_interface("field")
		toast("已离开建筑，交互面板关闭。")

func _sync_phase() -> void:
	if seen_phase == battle.phase and seen_mode == battle.mode: return
	var changed_phase: bool = seen_phase != battle.phase
	seen_phase = battle.phase
	seen_mode = battle.mode
	if changed_phase: world.warp_player(battle.player_pos)
	if battle.mode == "result":
		_record_report()
		_set_interface("report")
	elif changed_phase:
		_set_interface("field")
		toast("阶段间暂停：到指挥所按 E 布阵；WASD 仍可行走。")
	world.sync_battle(battle, 0)

func _process(delta: float) -> void:
	if town == null or world == null: return
	ui_clock += delta
	if ui_clock >= 0.1:
		ui_clock = 0
		_refresh_ui()
	if notice_time > 0:
		notice_time -= delta
		if notice_time <= 0: notice_label.text = ""
	if qa_enabled: _qa_tick(delta)

func _move_player(delta: float) -> void:
	var direction = Vector2.ZERO
	if interface_mode == "field" and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		direction.x = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
		direction.y = float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	var p: Vector2 = world.move_player(direction.normalized(), delta)
	if operating: town_pos = p
	else: battle.player_pos = p

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_ESCAPE:
		if interface_mode == "field": Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif interface_mode != "report": _set_interface("field")
	elif event.keycode == KEY_M and (operating or battle.mode != "result"):
		_set_interface("field" if interface_mode == "map" else "map")
	elif event.keycode == KEY_H and not operating and battle.mode == "combat":
		_set_interface("field" if interface_mode == "wheel" else "wheel")
	elif event.keycode >= KEY_1 and event.keycode <= KEY_5:
		if interface_mode == "wheel": wheel.select_squad(event.keycode - KEY_1)
		elif interface_mode == "command": _select_formation(event.keycode - KEY_1)
	elif event.keycode == KEY_E: _interact()
	elif event.keycode == KEY_SPACE and interface_mode == "field": _attack_nearest()
	elif event.keycode == KEY_Q and not operating and battle.mode == "combat": battle.retreat()
	elif event.keycode == KEY_F2:
		dev_open = not dev_open
		_set_interface("map")

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and interface_mode == "field" and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and world != null:
		world.look_camera(event.relative)

func _map_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed: return
	if interface_mode == "field":
		if event.button_index == MOUSE_BUTTON_LEFT:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else: _attack_nearest()
		return
	if interface_mode not in ["map", "command"]: return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		world.camera.size = maxf(38, world.camera.size - 3)
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		world.camera.size = minf(88, world.camera.size + 3)
		return
	if event.button_index != MOUSE_BUTTON_LEFT: return
	var local: Vector2 = event.position * Vector2(viewport.size) / viewport_container.size
	var p: Vector2 = world.ground_position(local)
	if not p.is_finite(): return
	if interface_mode == "command" and not operating and battle.mode == "deploy" and _near_building():
		if world.can_deploy_squad(p) and battle.place_squad(formation_slot, p):
			world.sync_battle(battle, 0)
			toast("第 %d 队已立即改位。" % (formation_slot + 1))
		else: toast("此处不能部署：请选择本阶段的防守区域。")
	elif interface_mode == "map":
		for building in world.get_building_definitions():
			if p.distance_to(building.center) < 4:
				_visit_building(building.id)
				return

func _visit_building(role: String) -> void:
	selected_role = role
	if _near_building() and (operating or (battle.mode == "deploy" and role == "headquarters")):
		_set_interface("command" if not operating else "building")
		return
	for building in world.get_building_definitions():
		if building.id == role:
			toast("%s 入口：%.0f, %.0f；请返回行走并靠近后按 E。" % [building.name, building.pos.x, building.pos.y])

func _nearest_building() -> Dictionary:
	var p: Vector2 = town_pos if operating else battle.player_pos
	var nearest: Dictionary = {}
	var distance: float = 3.4
	for building in world.get_building_definitions():
		if not operating and building.id != "headquarters": continue
		var d: float = p.distance_to(building.pos)
		if d <= distance:
			distance = d
			nearest = building
	return nearest

func _near_building() -> bool:
	var p: Vector2 = town_pos if operating else battle.player_pos
	for building in world.get_building_definitions():
		if building.id == selected_role: return p.distance_to(building.pos) <= 3.4
	return false

func _can_manage() -> bool:
	return operating and interface_mode == "building" and _near_building()

func _primary_action() -> void:
	if operating: _begin_battle()
	else: _start_combat()

func _assign_job(role: String, job: String) -> void:
	if not _can_manage(): return
	if role != selected_role and role != "unhired": return
	town.set_job(role, job)
	toast("已调遣：" + JOBS.get(job, job))

func _equip() -> void:
	if not _near_building() or selected_role != "headquarters": return
	if not _can_manage() and interface_mode != "command": return
	toast("分发装备：%d 套" % town.equip_soldiers())
	_refresh_ui()

func _deploy_ballista() -> void:
	if interface_mode != "command" or not _near_building() or battle.mode != "deploy": return
	toast("床弩已部署" if battle.deploy_ballista() else "器械不足，或床弩已满")
	world.sync_battle(battle, 0)

func _issue_order(slot: int, order: String) -> void:
	if operating or battle.mode != "combat": return
	var target: Vector2 = battle.player_pos + world.player_facing() * 12 if order == "advance" else Vector2.ZERO
	if battle.issue_order(slot, order, target):
		toast("第 %d 队：%s" % [slot + 1, {"follow":"跟随指挥官", "hold":"原地固守", "guard":"守卫阵位，有限追击", "advance":"向前推进"}[order]])
	elif battle.army_holding:
		toast("全军固守中，请先按 H 选择「全军恢复行动」。")
		return
	_set_interface("field")

func _issue_army_order(order: String) -> void:
	if operating or battle.mode != "combat": return
	if not battle.issue_all_order(order): return
	_set_interface("field")
	toast("全军固守：停止追击，所有士兵留在当前位置。" if order == "hold" else "全军恢复行动：允许守卫、有限追击与撤离。")

func _hire() -> void:
	if not _can_manage() or selected_role == "headquarters":
		toast("请先走到对应建筑前按 E。")
		return
	toast("已雇佣 5 名" + ROLES[selected_role] if town.hire(selected_role, 5) else "雇佣未完成：检查钱币、空闲居民与部门上限。")
	_refresh_ui()

func _dismiss() -> void:
	if not _can_manage() or selected_role == "headquarters": return
	toast("已遣散 5 人，回到自由居民岗位。" if town.dismiss(selected_role, 5) else "没有足够可遣散人员。")
	_refresh_ui()

func _send_support() -> void:
	if not _can_manage() or selected_role != "supply": return
	toast("已发出运输车；10 木石已扣除。邻镇为本地模拟。" if town.send_transfer("material", 10) else "运输未发出：库存不足或运输队已满。")

func _begin_battle() -> void:
	if not _can_manage() or selected_role != "headquarters": return
	operating = false
	recorded = false
	used_dev_tools = false
	seen_mode = ""
	seen_phase = -1
	walk_target = Vector2.INF
	battle = Battle.new()
	battle.setup(town, config)
	battle.begin_battle()
	battle.player_pos = town_pos
	battle.movement_resolver = Callable(world, "resolve_npc_motion")
	seen_phase = battle.phase
	seen_mode = battle.mode
	world.sync_battle(battle, 0)
	world.warp_player(battle.player_pos)
	run_counter += 1
	_set_interface("command")
	toast("已进入暂停布阵。选择分队并点击地面布置，然后确认交战。")

func _select_formation(index: int) -> void:
	formation_slot = index
	_build_sidebar()

func _reinforce() -> void:
	if interface_mode != "command" or not _near_building() or battle.mode != "deploy": return
	var n: int = town.reinforce()
	toast("预备队补入 %d 人；伤员占用的编制不补员。" % n)

func _start_combat() -> void:
	if interface_mode != "command" or not _near_building() or battle.mode != "deploy": return
	battle.start_combat()
	walk_target = Vector2.INF
	_build_sidebar()
	_set_interface("field")
	toast(PHASES[battle.phase] + "：交战开始。H 下达小队军令，空格挥击，E 交互。")

func _attack_nearest() -> void:
	if operating or battle.mode != "combat": return
	var nearest = Vector2.INF
	var distance: float = INF
	for agent in battle.agents:
		if agent.team == "enemy" and agent.alive:
			var d: float = battle.player_pos.distance_squared_to(agent.pos)
			if d < distance:
				distance = d
				nearest = agent.pos
	if nearest != Vector2.INF:
		battle.attack(nearest)
		world.show_attack(battle.player_pos)

func _interact() -> void:
	if operating or battle.mode == "deploy":
		var building: Dictionary = _nearest_building()
		if not building.is_empty():
			_visit_building(building.id)
		else:
			toast("请走近指挥所按 E 布阵。" if not operating else "请走近建筑入口按 E。")
	elif battle.mode == "combat":
		if battle.phase == 0 and battle.player_pos.distance_to(Vector2(15, -17)) <= 5:
			var struck: bool = battle.strike_supply()
			toast("敌军粮草已摧毁，士气固定扣除 30 点。" if battle.supply_destroyed else ("正在破坏粮草，继续按 E。" if struck else "请再靠近粮草，或等待动作冷却。"))
		elif battle.phase == 3 and battle.player_pos.distance_to(Vector2(21, 22)) <= 5:
			if battle.escaped < town.resident_count() + town.soldier_count() and Time.get_ticks_msec() / 1000.0 > escape_confirm_until:
				escape_confirm_until = Time.get_ticks_msec() / 1000.0 + 5
				toast("仍有人尚未撤出。等待队列，或 5 秒内再次按 E 确认带领已撤出者离开。")
			else:
				battle.escape_player()
		else:
			toast("床弩发射！" if battle.use_ballista() else "附近没有可用器械，或器械正在装填。")

func _record_report() -> void:
	if recorded: return
	recorded = true
	var report: Dictionary = battle.report.duplicate(true)
	report["local_id"] = "%d-%d" % [int(Time.get_unix_time_from_system()), run_counter]
	report["simulation"] = "local_only"
	report["development_tools_used"] = used_dev_tools or qa_enabled
	reports.append(report)
	total_merit += int(report.get("merit", 0))

func _return_town() -> void:
	operating = true
	town_pos = Vector2(0, 12)
	walk_target = Vector2.INF
	world.warp_player(town_pos)
	world.sync_town(town_pos, 0)
	_set_interface("field")
	toast("镇务已恢复实时运行。检查伤员、城防和战利品池。")

func _reset_demo() -> void:
	town = Town.new()
	town.setup(config)
	battle = Battle.new()
	battle.setup(town, config)
	operating = true
	town_pos = Vector2(0, 12)
	walk_target = Vector2.INF
	world.warp_player(town_pos)
	world.sync_town(town_pos, 0)
	_set_interface("field")
	toast("已建立新的 100 居民 + 50 军人试验镇。保留本机战报。")

func _save() -> void:
	var f = FileAccess.open("user://savegame.json", FileAccess.WRITE)
	if f == null:
		toast("保存失败：本地存档目录不可写。")
		return
	f.store_string(JSON.stringify({"version":1,"town":town.snapshot(),"reports":reports,"merit":total_merit}, "\t"))
	toast("镇务已保存。离线时间不累计生产。")

func _load_save() -> void:
	if not FileAccess.file_exists("user://savegame.json"):
		toast("尚无镇务存档。")
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string("user://savegame.json"))
	if not data is Dictionary or not data.has("town"):
		toast("存档格式无效。")
		return
	if not data.town is Dictionary or not town._valid_snapshot(data.town):
		toast("存档校验失败，保留当前镇务。")
		return
	town.restore(data.town)
	reports = data.get("reports", [])
	total_merit = int(data.get("merit", 0))
	_build_sidebar()
	toast("镇务已读取。")

func toast(message: String) -> void:
	if is_instance_valid(notice_label):
		notice_label.text = message
	notice_time = 7.0

func _refresh_ui() -> void:
	var info: String = "钱币  %d" % town.money
	for item in ITEMS:
		info += "    ·    %s  %d" % [ITEMS[item], int(town.resources.get(item, 0))]
	resource_label.text = info
	battle_guide.visible = interface_mode == "field" and (operating or battle.mode == "deploy")
	if battle_guide.visible:
		var p: Vector2 = town_pos if operating else battle.player_pos
		for building in world.get_building_definitions():
			if building.id != "headquarters": continue
			var target: Vector2 = building.pos - p
			var facing: Vector2 = world.player_facing()
			var right = Vector2(-facing.y, facing.x)
			var bearing: int = posmod(roundi(atan2(target.dot(right), target.dot(facing)) / (PI / 4)), 8)
			var direction: String = ["前方", "右前方", "右侧", "右后方", "身后", "左后方", "左侧", "左前方"][bearing]
			if target.length() <= 3.4:
				battle_guide_text.text = "已到指挥所入口 · 按 E 打开\n" + ("点击「迎战来敌」，进入战前布阵。" if operating else "布阵后点击「确认布阵 · 开始交战」。")
			else:
				battle_guide_text.text = "指挥所：%s · %.0f 米\n走近入口按 E，再选择迎敌。\n按 M 查看指挥所位置。" % [direction, target.length()]
			break
	if primary_action.visible: primary_action.disabled = not _near_building()
	interaction_hint.text = ""
	if interface_mode == "field":
		if operating or battle.mode == "deploy":
			var near: Dictionary = _nearest_building()
			if not near.is_empty(): interaction_hint.text = "[E] " + near.name + (" · 迎敌 / 布阵" if near.id == "headquarters" else "")
		elif battle.mode == "combat":
			interaction_hint.text = "[E] 附近目标 / 器械   [H] 小队军令"
	if operating:
		state_label.text = "烽火连绵  ·  镇务运行中"
		phase_label.text = "望烽镇   /   实时筹备 · v" + str(ProjectSettings.get_setting("application/config/version", "0.5.1"))
		objective_label.text = "雇佣 → 采集与制作 → 修缮与布防 → 接敌。所有作业按实际经过的时间推进。"
		roster_label.text = "  运营表现：15 人 / 实际人口：%d" % (town.resident_count() + town.soldier_count())
		if labels.has("population"): labels.population.text = "居民 %d   ·   军人 %d / 50   ·   自由居民 %d\n已装备 %d 人   ·   待清扫 %d 份" % [town.resident_count(), town.soldier_count(), town.count_role("unhired"), town.equipped_count(), town.salvage]
		if labels.has("workers"): labels.workers.text = "在岗 %d / 20   ·   健康 %d" % [town.count_role(selected_role), town.count_role(selected_role, true)]
		if labels.has("hiring"): labels.hiring.text = "雇佣费用 %d 钱 / 人   ·   %s" % [config.hire[selected_role].hire_cost, "已到建筑前" if _near_building() else "请靠近入口"]
		if hire_button != null: hire_button.disabled = not _near_building()
		if bars.has("job"):
			if bars.has("job"): bars.job.value = float(town.job_progress.get(selected_role, 0)) * 100.0
			if labels.has("job"): labels.job.text = "当前批次  %d%%" % bars.job.value
			if labels.has("job_status"): labels.job_status.text = str(town.job_status.get(selected_role, "等待调遣"))
		if labels.has("gather"): labels.gather.text = "%s · %s" % [JOBS.get(town.jobs.get("unhired", ""), "待安排"), town.job_status.get("unhired", "")]
		for id in ["outer", "street", "evac"]:
			if not bars.has(id): continue
			bars[id].value = float(town.facilities.get(id, 0))
			labels[id].text = {"outer":"木墙", "street":"街区", "evac":"疏散门"}[id] + "   %d / 100" % bars[id].value
		if labels.has("transport"): labels.transport.text = "本地模拟邻镇 · 运输记录 %d 车；实际扣货、延时到账。" % town.transfers.size()
	else:
		wheel.set_army_holding(battle.army_holding)
		state_label.text = "战后结算" if battle.mode == "result" else ("战场暂停" if battle.mode == "deploy" else "正在交战")
		phase_label.text = "  →  ".join(PHASES.slice(0, battle.phase + 1))
		if battle.army_holding and battle.mode != "result": phase_label.text += "  |  全军固守"
		var enemy_cap: int = int(config.globals.raid_enemy_cap if battle.phase == 0 else config.globals.battle_enemy_cap)
		roster_label.text = "敌 %d/%d   友 %d/%d   士气 %.1f   生命 %.0f/%.0f" % [battle.enemy_count(), enemy_cap, battle.ally_count(), 30 if battle.phase == 0 else 50, battle.morale, battle.player_hp, battle.player_max_hp]
		if battle.phase == 0 and battle.mode != "result":
			var remaining: int = ceili(battle.raid_next_reinforcement_in())
			if remaining >= 0:
				roster_label.text += "\n下批援军 %02d:%02d  ·  +%d 人" % [remaining / 60, remaining % 60, battle.raid_next_reinforcement_count()]
				if battle.raid_pending_reinforcements > 0: roster_label.text += "  ·  待入场 %d" % battle.raid_pending_reinforcements
		objective_label.text = ["主动突袭粮仓守军，破坏粮草固定削减 30 点士气。3 分钟后敌军分批增援；Q 撤回木墙。", "守住主门，消灭敌军士气即可获胜。城门被破后暂停，重新布置巷战防线。", "守住三个街区。敌军同时占领全部点位后进入撤离；士气归零则守城成功。", "镇已失守，护送军民通过东南小门。削尽敌军士气会停止追击。按 E 撤出指挥官。"][battle.phase]
		if battle.mode == "deploy": objective_label.text = "NPC 与生产暂停。到指挥所按 E 布阵，选队并点击地图立即改位。"
		if battle.mode == "result":
			objective_label.text = "战斗已结束。" + ("守住了望烽镇，可返回镇务清扫、救治与修缮。" if battle.report.get("town_held", false) else "城镇失守，撤出军民和伤亡已按真实名册结算。")
			roster_label.text = "  已投入敌军残余：%d" % battle.report.get("remaining_enemies", 0)
			return
		if bars.has("morale"): bars.morale.value = battle.morale
		if labels.has("morale"): labels.morale.text = "敌军士气   %s / 100" % ("<0.1" if battle.morale > 0 and battle.morale < 0.1 else "%.1f" % battle.morale)
		if bars.has("health"): bars.health.value = battle.player_hp / maxf(1, battle.player_max_hp) * 100
		if labels.has("health"): labels.health.text = "指挥官   %d / %d" % [battle.player_hp, battle.player_max_hp]
		if labels.has("army"): labels.army.text = "军队名册 %d / 50  ·  已装备 %d\n在场：我军 %d / 敌军 %d" % [town.soldier_count(), town.equipped_count(), battle.ally_count(), battle.enemy_count()]
		if labels.has("formation"):
			var p: Vector2 = battle.formations[formation_slot]
			if labels.has("formation"): labels.formation.text = "已选第 %d 队  ·  布置 %.0f, %.0f" % [formation_slot + 1, p.x, p.y]
		if bars.has("supply"):
			if bars.has("supply"): bars.supply.value = battle.supply_hp
			if labels.has("supply"): labels.supply.text = "敌军粮草：" + ("已破坏 · 不再重复扣士气" if battle.supply_destroyed else "完整 · 靠近后按 E")
		if bars.has("gate"):
			if bars.has("gate"): bars.gate.value = battle.gate_hp
			if labels.has("gate"): labels.gate.text = "主城门耐久   %.0f" % battle.gate_hp
		for i in range(3):
			var id: String = "point" + str(i)
			if bars.has(id): bars[id].value = battle.points[i]
		if bars.has("evac_count"):
			var baseline: int = battle._baseline.size()
			if bars.has("evac_count"): bars.evac_count.value = battle.escaped / maxf(1, baseline) * 100
			if labels.has("evac_count"): labels.evac_count.text = "撤出军民   %d / %d 人" % [battle.escaped, baseline]
		if labels.has("battle_info"): labels.battle_info.text = "击败敌军 %d   ·   作战 %.0f 秒\n床弩 %d / 2   ·   持续补充敌军，无固定总预算" % [battle.kills, battle.elapsed, battle.ballista_count]

func _qa_visit_hq() -> void:
	for building in world.get_building_definitions():
		if building.id == "headquarters":
			world.warp_player(building.pos)
			if operating: town_pos = building.pos
			else: battle.player_pos = building.pos
	_visit_building("headquarters")

func _qa_tick(delta: float) -> void:
	qa_time += delta
	qa_samples.append(delta * 1000)
	if not operating:
		qa_max_enemies = maxi(qa_max_enemies, battle.enemy_count())
		qa_max_allies = maxi(qa_max_allies, battle.ally_count())
	if qa_step == 0 and qa_time > 1.5:
		qa_step = 1
		_qa_capture("v05_01_town")
	elif qa_step == 1 and qa_time > 3:
		qa_step = 2
		_qa_visit_hq()
		town.equip_soldiers()
		_begin_battle()
	elif qa_step == 2 and qa_time > 5:
		qa_step = 3
		_qa_capture("v05_02_deploy")
	elif qa_step == 3 and qa_time > 7:
		qa_step = 4
		_start_combat()
		battle.player_pos = Vector2(0,-8)
		world.warp_player(battle.player_pos)
	elif qa_step == 4 and qa_time > 10:
		qa_step = 5
		_set_interface("wheel")
	elif qa_step == 5 and qa_time > 12:
		qa_step = 6
		await _qa_capture("v05_03_wheel")
		_issue_order(0,"follow")
	elif qa_step == 6 and qa_time > 14:
		qa_step = 7
		battle.retreat()
		_sync_phase()
		_qa_visit_hq()
		_deploy_ballista()
		_start_combat()
		world.warp_player(Vector2(0,6))
		battle.player_pos = Vector2(0,6)
	elif qa_step == 7 and qa_time > 17:
		qa_step = 8
		await _qa_capture("v05_04_wall")
		battle.advance_phase()
		_sync_phase()
		_qa_visit_hq()
		_start_combat()
		world.warp_player(Vector2(0,14))
		battle.player_pos = Vector2(0,14)
	elif qa_step == 8 and qa_time > 20:
		qa_step = 9
		await _qa_capture("v05_05_street")
		battle.advance_phase()
		_sync_phase()
		_qa_visit_hq()
		_start_combat()
		world.warp_player(Vector2(0,16))
		battle.player_pos = Vector2(0,16)
	elif qa_step == 9 and qa_time > 24:
		qa_step = 10
		_qa_capture("v05_06_evac")
		battle.debug_set_morale(0)
	elif qa_step == 10 and qa_time > 27:
		qa_step = 11
		battle.player_pos = Vector2(21,22)
		world.warp_player(battle.player_pos)
		battle.escape_player()
	elif qa_step == 11 and qa_time > 29:
		qa_step = 12
		_qa_capture("v05_07_report")
	elif qa_step == 12 and qa_time > 31:
		qa_step = 13
		print("UI_SMOKE_COMPLETED frames=%d enemies=%d allies=%d" % [qa_samples.size(),qa_max_enemies,qa_max_allies])
		get_tree().quit()

func _qa_capture(id: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../outputs/qa"))
	var img: Image = get_viewport().get_texture().get_image()
	var error: Error = img.save_png("res://../outputs/qa/" + id + ".png")
	print("SCREENSHOT ", id, " error=", error)

