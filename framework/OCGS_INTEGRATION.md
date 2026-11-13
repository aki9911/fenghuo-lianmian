# OpenCodeGameStudios 项目适配

来源：https://github.com/striderZA/OpenCodeGameStudios

固定提交：0ac3a5584bb8b86046d3a040508bf513c93ccf6b（2026-11-09 审阅）。选用文件与 SHA256 见 `third_party/ocgs/manifest.json`，许可证见同目录 LICENSE。

## 已采用

- 根 AGENTS.md：项目入口、文件归属、跨模块并行分工、运行验证。
- `.agents/skills/fenghuo-design-check`：跨分册一致性、变更传播与范围检查的本地适配。
- `.agents/skills/fenghuo-prototype`：小步原型、Godot运行与性能证据的本地适配。
- `.codex/agents/`：三份项目专题角色；已授权当前任务可通过同等任务指令委派，无须等待新会话发现配置。
- `production/session-state/active.md`、`production/validation.md`：会话续接及实测记录。

## 有意调整

保留六份中文分册，直接映射其路径；无需先生成英文GDD或ADR目录。删除逐文件审批、多层导演、模型强制指定和全模块加载。持续刷新与屏外战斗不受可见性影响。Excel导入校验与Godot实测由本项目实现。

只保留选用源码参考，不安装其OpenCode插件、Git钩子或MCP配置，不改全局配置。不运行上游安装器，以免引入与当前工具不匹配的规则。更新上游须对比固定提交及本地适配差异，不能强制覆盖。

## 维护入口

规则修改先更新所属分册，再检查 `game/data` 与 `game/scripts`；测试见 `game/tests`。配置导出工具读取原工作簿，生产参数未确认时必须显式使用原型覆盖配置，严格模式应报出缺失项。
