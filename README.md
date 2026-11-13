# 烽火连绵 · 边镇守御

Godot 4.7.2 第三人称 PvE 可玩灰盒，贺思棋个人系统策划与 AI 辅助开发项目。以《燕云十六声》版本内容消耗后的持续参与需求为设计假设，验证「实时运营 → 暂停布阵 → 实时防守 → 撤离/战报 → 战后恢复」。

当前版本 **v0.5.1**：新增指挥所方向指引，迎敌/开战按钮固定显示。已有网页可用 Ctrl+F5 重新加载。

## 浏览器试玩

**[在线试玩](https://aki9911.github.io/fenghuo-lianmian/)** · [直接进入游戏](https://aki9911.github.io/fenghuo-lianmian/game.html)。已完成首次部署，后续部署状态见 [Actions](https://github.com/aki9911/fenghuo-lianmian/actions)。

桌面键鼠操作，浏览器需支持 WebGL 2。无需安装 Godot 或下载可执行程序；首次加载约 53 MB 游戏资源。

- 点击游戏画面捕获鼠标，WASD 移动，鼠标转向，Esc 释放鼠标。
- 走近建筑入口按 E 交互；M 打开全镇总览。
- 沿右上角迎敌指引走到指挥所，按 E，点击面板顶部「迎战来敌」。布阵后点击顶部「确认布阵 · 开始交战」。
- 实时战斗按 H 打开军令轮盘，1–5 选队，选择跟随、驻守、推进。
- 空格或左键攻击；城外 Q 退守木墙，E 破坏粮仓/操作床弩。

## 当前范围

100 居民、50 军人的实时运营和四阶段防守；正常战斗 100 敌军/50 友军在场上限，敌军持续补充。共享 NPC 行为脚本、实体碰撞、第三人称相机、建筑前交互和小队指挥已经接通。当前使用自制灰盒模型，未实现正式动作技能与动画。

本地战报、模拟邻镇支援已实现。全服战区、真实玩家互助、长期排行榜、政府支援和动态故事为后续设计，当前没有联机后台。

## 查看与编辑

使用 Godot 4.7.2 导入 `game/project.godot`，F5 运行。打开 `game/scenes/wangfeng_town.tscn` 编辑城镇；独立角色场景位于 `game/scenes/actors/`。替换 Visual 下的模型，保留根节点公共 Script 与 CollisionShape3D。[角色和相机编辑教程](docs/编辑角色与相机.md)。

[六份策划分册](策划文档/00_总纲与协作约定.md) · [项目经历介绍](docs/项目介绍.md) · [验证记录](production/validation.md)

## 更新与部署

`.github/workflows/pages.yml` 会在 main 分支的游戏/网页发生变更时，获取官方 Godot、执行核心规则测试、重新导出 Web 并部署 GitHub Pages。首次需在仓库 Settings → Pages → Build and deployment 选择 GitHub Actions。发布成功后试玩地址保持不变。

Web 导出关闭线程，兼容普通静态托管。网页存档位于浏览器本地存储，同一浏览器保留；清理站点数据会清除存档。发布源码不包含编辑器远程控制插件、私人简历、账号配置或开发存档。

## 来源

非官方玩法研究，与《燕云十六声》官方无隶属关系。裁剪的 OpenCodeGameStudios 工作流来源见 [整合说明](framework/OCGS_INTEGRATION.md)，上游 MIT 许可证保留于 `third_party/ocgs/LICENSE`。Noto Sans SC 字体遵循 `game/assets/fonts/OFL.txt`。
