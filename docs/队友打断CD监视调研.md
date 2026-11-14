# 队友打断 CD 监视调研

> 基于当前插件源码的静态调研，未在游戏内实测。以下行号均为调研时版本。

## 核心结论

主模块为 `KiraUI-Plugin_Interrupts.lua`（`KiraUI-Plugin.toc:70` 加载）。它不使用战斗日志 `COMBAT_LOG_EVENT_UNFILTERED`，也不通过插件消息同步打断 CD，队友无需安装同插件。

实现采用两条路径：**可读的打断技能施放直接计时；技能 ID 被 secret 隐藏时，通过敌方施法中断事件和暴雪打断统计确认、推断归属。** 队友冷却主要是本地技能表估算，不是真实冷却同步。

## 主要事件

| 事件 | 用途 | 源码位置（Interrupts.lua） |
| --- | --- | --- |
| `UNIT_SPELLCAST_SUCCEEDED` | 监听 player、party1–4 及各自宠物；可读 spellID 命中 KICKS 表就起 CD | 159–166、902–944、1220–1226、1260–1263 |
| `UNIT_SPELLCAST_INTERRUPTED` | 获取敌方施法中断线索，尝试通过 interruptedBy GUID 定位打断者 | 1167–1202、1277–1278 |
| `UNIT_SPELLCAST_CHANNEL_STOP` | 补充引导中断线索；第四参数非 nil 或为 secret 才处理 | 1279–1280 |
| `DAMAGE_METER_COMBAT_SESSION_UPDATED` | 仅处理 Interrupts 类型，确认中断线索并辅助推断打断者 | 976–1074、1206–1218、1240–1253 |
| `SPELL_UPDATE_COOLDOWN` | 通过 C_Spell.GetSpellCooldown 校正玩家自己的 CD，不校正队友真实 CD | 523–591、1286–1287 |

## 事件处理逻辑

### 1. 直接识别施放

`UNIT_SPELLCAST_SUCCEEDED` 回调只取 spellID，单位使用各独立 frame 的已知 token，宠物归属于其主人。

`OnCast()` 遇到 secret spellID 直接返回；可读时查 `KICKS[spellID]`，命中且职业匹配后，队友执行 `StartCooldown(row, GetTime(), MemberCd(row))`。

**此路径记录“打断技能施放成功”，不是“实际打断成功”。可读 ID 的空踢也会计时，不受 meterConfirm 约束。**

### 2. 敌方中断 + 统计补偿

敌方事件按 `(unit, castGUID, spellID, interruptedBy)` 使用参数；castGUID 忽略，spellID 是敌方被中断的法术，不能用它识别队友的打断技能。

打断者 GUID 可读时映射到队员/宠物；隐藏或缺失时等待推断。默认 `observe=true`、`meterConfirm=true`，中断线索先入队，等待打断统计更新。

统计通过 `C_DamageMeter.GetCombatSessionFromType(..., Enum.DamageMeterType.Interrupts)` 读取 Current / Overall 的 combatSources。它根据唯一上榜者、唯一新增者或唯一排名上升者推断，并用姓名、职业、专精图标、本地玩家标志匹配队员，**不比较打断次数数值增量**。

中断线索与统计更新按队列顺序、时间差不超过 1 秒配对；超过 1.5 秒的旧项在后续配对时清理。统计更新单独不会起 CD。仍不能确定归属时，尝试认领为自己的近期打断，否则猜一个候选 ready 队友，优先表内 CD 较短者。

## CD 来源与辅助事件

- 队友时长来自 `KICKS` 表及职业、专精、治疗角色例外（61–115、178–182、631–635）。例如贼 15 秒、法师 21 秒、战士拳击 13.5 秒、萨满 12 秒／治疗 30 秒；这些是源码假设，不保证覆盖全部天赋和版本变化。
- 队友专精由 inspect 获取；未完整检测天赋减 CD 或重置。队友倒计时到期直接 ready。
- 玩家自身使用真实冷却 API；数值可读时校正，隐藏时估算，并可通过状态检测提前结束或延长（481–591）。
- 显示通过 OnUpdate 每约 0.05 秒刷新（575–622）。
- 辅助事件：`PLAYER_ENTERING_WORLD`、`GROUP_ROSTER_UPDATE`、`PLAYER_SPECIALIZATION_CHANGED`、`INSPECT_READY`、`SPELLS_CHANGED`、`UNIT_NAME_UPDATE`、`UNIT_PET`、`DAMAGE_METER_RESET`（1228–1236、1272–1297）。主要用于维护成员、专精、技能和统计快照。

## 限制与验证

- secret spellID 没有解密机制；隐藏 ID 的空踢可能漏记，成功打断也可能因确认失败而漏记或误归属。
- `observe` 只控制敌方观察补偿路径；关闭后可读的施放成功仍可计时。`meterConfirm` 同样不限制直接施放路径。
- 仅枚举 player / party1–4，不是完整 raid1–40 监视。
- 插件的 `CHAT_MSG_ADDON` 通信只用于版本通告，不传打断 CD。
- 默认模块 `enable=false`，实际是否启用由保存配置决定（27–50）。
- 可在游戏内执行 `/kirakick`，查看监听状态、secret 计数、统计确认／猜测次数和采用的 CD（1299 起）。

**总结：施放事件直接识别 + 敌方中断／暴雪统计补偿 + 本地技能表倒计时；不等于精确的队友真实 CD 同步。**
