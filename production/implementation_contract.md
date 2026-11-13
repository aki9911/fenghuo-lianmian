# 首个可玩版本模块契约

主 agent 维护此接口。所有 GDScript 使用显式类型或 `=` 避免对 Variant 使用 `:=` 推导。

## TownState（game/scripts/core/town_state.gd）

继承 RefCounted，class_name TownState。`setup(config:Dictionary)` 初始化；`tick(delta:float)` 只在主控制器运营态调用。

公开：`config:Dictionary`, `money:int`, `resources:Dictionary`, `people:Array`（字典：id:int, origin:String居民/军人用resident/soldier, role:String, health:String healthy/wounded/dead/missing, escaped:bool），`jobs:Dictionary`（部门名→作业ID）, `facilities:Dictionary`（outer/street/evac→0..100）, `salvage:int`, `messages:Array`, `transfers:Array`。

方法：`count_role(role:String, healthy_only:bool=false)->int`, `resident_count()->int`, `soldier_count()->int`, `hire(role:String, amount:int)->bool`, `dismiss(role:String,amount:int)->bool`, `set_job(role:String, job_id:String)->void`, `reinforce()->int`, `equip_soldiers()->int`, `equipped_count()->int`, `healthy_soldier_ids()->Array`, `mark_casualty(id:int,wounded:bool)->void`, `send_transfer(item:String,amount:int)->bool`, `snapshot()->Dictionary`, `restore(data:Dictionary)->void`。`people`中军人需有equipped:bool。居民role为unhired/engineer/medical/supply/reserve，军人role为soldier。`job_progress:Dictionary`供UI读取（0..1），`job_status:Dictionary`供UI显示文本。

## BattleModel（game/scripts/core/battle_model.gd）

继承RefCounted，class_name BattleModel。`setup(town_ref,config:Dictionary)`；`begin_battle()->void`；`start_combat()->void`；`advance_phase()->void`（若已撤离则不再晋级）；`tick(delta:float)->void`。

公开：`town`, `config`, `phase:int`（0突袭1木墙2巷战3撤离）, `mode:String`（deploy/combat/result）, `morale:float`, `player_pos:Vector2`, `player_hp:float`, `player_max_hp:float`, `agents:Array`（每实体字典id:int,team:String enemy/ally,pos:Vector2,hp:float,max_hp:float,kind:String,soldier_id:int,alive:bool）, `gate_hp:float`, `points:Array`（占领进度0..100）, `supply_destroyed:bool`, `supply_hp:float`, `kills:int`, `elapsed:float`, `report:Dictionary`, `escaped:int`, `evac_groups:Array`（pos:Vector2,count:int）, `formations:Array`（5个槽位的Vector2，主控在部署时可改）, `ballista_count:int`。

方法：`attack(target:Vector2)->void`, `strike_supply()->bool`（要求玩家靠近/攻击粮仓；可被测试直接设置位置）, `use_ballista()->bool`, `retreat()->void`, `escape_player()->void`, `enemy_count()->int`, `ally_count()->int`, `deploy_ballista()->bool`, `debug_set_morale(value:float)->void`（仅开发测试入口）。报告至少result:String/town_held:bool/kills:int/escaped:int/baseline:int/civilian_escaped:int/dead:int/wounded:int/missing:int/remaining_enemies:int/merit:int。

## 世界坐标

模拟 Vector2(x,z) 与3D的(x,0,z)映射。范围x=-25..25，z=-28..28。普通阶段敌军自z=-24推进，突袭阶段在粮仓周边巡逻防守；突袭玩家起点(0,8)，粮仓(15,-17)，前沿旗(0,4)；木墙主门(0,0)，玩家在墙后z=6；街区三点(-12,7),(0,11),(12,7)。v0.5 撤离居民集结于(0,11)，沿(5,10)→(12,14)→(12,21)→小门(21,22)行进；守军等待军民队列，保留通行走廊。阶段间暂停布阵。主控负责输入，玩家控制器处理物理移动；战斗模型负责损伤、刷新、人数和结果，公共 NPC 脚本负责行为决策。UI读取模型，不复制胜负判定。

## v0.5 表现与指挥接口

`world_view.gd` 实例化可编辑 `actors/*.tscn`，以稳定的队伍/实体 ID 绑定中央名册。`resolve_npc_motion` 经真实 CharacterBody3D 碰撞解析位移，绑定到 BattleModel 的 `movement_resolver`；屏外实体仍参与模拟。`can_deploy_squad` 校验全部队员的碰撞占位，不允许阵列被建筑/边界截断。

`BattleModel.place_squad` 在 deploy 时立即调整实体位置，保留 ID 和生命；`issue_order` 在 combat 时下达 follow/guard/hold/advance。`issue_all_order("hold"/"guard")` 控制全军固守与恢复；恢复行动继续固守前各队命令；`army_holding` 期间分队命令拒绝，固定每名友军自己的位置，不允许分离、追击或自动撤离移动。阶段暂停冻结 NPC、经济、刷新、占点与撤离，但玩家仍可走到指挥所。`main.gd` 统一管理 field/map/building/command/wheel 界面；经营和布阵入口分别校验建筑距离和阶段，H 轮盘不暂停交战。

## 配置

`game/data/runtime_config.json`: {schema_version:1,config_version:String,mode:"prototype",globals:Dictionary,hire:Dictionary, jobs:Dictionary, inputs:Dictionary,combat:Dictionary,initial_resources:Dictionary}。

全局参数沿用Excel ID；生产作业键沿用作业ID，值包含team_id/work_required/rate_per_person_sec/output_id/output_qty；inputs为job_id→{item_id:qty}；hire为role→{max_workers:20,hire_cost:int}。由配置导出模块提供文件，战斗临时所需参数可读config.combat.get(key,default)，新增时请告知主agent。

## v0.6 突袭接口

`raid_next_reinforcement_in()->float` 与 `raid_next_reinforcement_count()->int` 为主控提供下批增援倒计时和人数。计时仅使用第一阶段实际交战时间，初始 30 敌军，180/240/300 秒分别 +10/+10/+15，360 秒起每 60 秒 +20，敌军在场上限 100。达到上限的待入场援军在释放空位后入场（原型队列处理），补员不恢复士气；部署暂停、结算、阶段转换和士气归零遵循调度取消/去重边界。
