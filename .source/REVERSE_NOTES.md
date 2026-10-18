# pingspy 逆向笔记（dontstarve x64，IDA 9.4 实证）

分析对象：`bin64/dontstarve_steam_x64.exe`（客户端与 dedicated server 引擎代码一致）
分析日期：2026-10-18；游戏 `version.txt` 以安装目录为准

## 切入点

- `TheNet` 的 Lua 方法注册表：字符串 `"GetNetworkStatistics"` 的数据交叉引用即
  `luaL_Reg` 数组项，`+8` 为 Lua C 包装函数地址。
- 所有 TheNet 包装函数统一模式：`mov rcx, cs:qword_140672E50`（cNetwork 单例全局）→
  `call cNetwork::<方法>`。

## 关键结构（运行时验证方式见下）

| 项 | 值 | 证据 |
|---|---|---|
| cNetwork+0x2B0 | RakPeer* | `GetNetworkStatistics` 三次解引用并判空 |
| cNetwork+0x308/309/30A | 布尔标志 | `GetPing`/`GetNetworkStatistics` 判定连接状态 |
| cNetwork+0x328 | 当前连接标识（含 g/index） | `GetPing` 取本地连接时使用 |
| vtable 槽 42（+0x150） | `GetAveragePing(AddressOrGUID*)` | `avg_ping` 字段生成码 `call qword ptr [rax+150h]` |
| vtable 槽 43（+0x158） | `GetLastPing(AddressOrGUID*)` | `ping` 字段生成码及 `GetPing` 实现 |
| AddressOrGUID | 10 字节：`uint64 g` @0、`uint16 systemIndex` @8 | 默认构造 `sub_1403F3CD0`：写 g 与 0xFFFF，无 systemAddress 成员（fork 精简） |
| UNASSIGNED 标识 | g=全 `FF`、index=0xFFFF | 常量 `qword_14062BE70` 字节 `ff ff ... ff ff` |

与开源 RakNet 4.081 对比：ping 区段（槽 42/43）一致；`GetStatistics` 区段（引擎调槽 86
vs 开源 83）存在差异，fork 在中段插入了虚函数。**勿用开源槽位表外推中后段**。

## 行为语义

- `GetLastPing`/`GetAveragePing` 无连接或未完成 ping 测量时返回 `-1`。
- 引擎侧 `GetPing()` 即 `GetLastPing(本地连接标识)`；客户端 HUD 的 ping 与服务器原生
  `PN_QueryLast` 同语义。
- `TheNet:GetClientTable()` 条目的 `netid` 与 RakPeer 连接的 `RakNetGUID.g` 的对应关系
  待实机确认（预期 `netid == g`，SteamID64）。

## 双 exe 差异与单例 RVA（探针 6~11 实证，2026-10-18）

| exe | ImageBase | cNetwork 单例全局 | RVA |
|---|---|---|---|
| dontstarve_steam_x64.exe | 0x140000000 | qword_140672E50 | 0x672E50 |
| dontstarve_dedicated_server_nullrenderer_x64.exe | 0x140000000 | qword_1405EC780 | 0x5EC780 |

dedicated exe 仅 7MB（无渲染变体），其 `cNetwork::GetNetworkStatistics`（0x1401E47A0）
与客户端逐指令一致：`+0x2B0` RakPeer、槽 `0x150/0x158`（avg_ping/ping 生成码）均相同。
定位法：`.rdata` 中 qword 搜索 `"GetNetworkStatistics"` 字符串 VA → luaL_Reg 项 → +8 包装
函数 → `mov rcx, cs:qword_XXX` 即单例全局；实现体再验偏移与槽位。

## 教训：扫描 + 行为试探会崩服

初版"扫 .data/.bss 每个指针当候选 + 真调虚函数验证"曾导致 dedicated server 崩溃：
vtable 校验放宽后，结构误判的假候选上执行了真实调用。结论：**行为试探绝不能用于
身份未定的候选**；改为 RVA 常量直读（引擎自己写的单例指针）+ 纯结构校验，
校验失败只回退，永不崩。

## ClientObject 树与 userid→guid 映射（探针 13~15 实证，2026-10-18）

- 管理器：`*(cNetwork + 0x328)`；ClientObject 红黑树 head：`*(管理器 + 0x3D0)`
  （`sub_1401E4320: mov rax,[rcx+328h]; add rax,3C8h`，GetClientTable 里 `mov r8,[rax+8]`）
- std::tree 节点：`_Left@0`、`_Right@0x10`、`_Isnil@0x31`、值（ClientObject*）`@0x28`
- ClientObject：`RakNetGUID @0x1A0`（g@0）、`userid std::string @0x1C0`、`netid std::string @0x1E8`
  （证据：认证日志 `[ClientObject] Initialized (authenticated) on server: guid=%s userid=%s netid=%s`
  打印函数 0x1401f2f90 直接从这些偏移取参；GetClientTable 遍历同一棵树）
- 关键事实：`RakNetGUID.g ≠ netid(SteamID64)`（同一日志里两者是不同的数），所以按 netid 当 guid
  查询必败；必须经 userid→ClientObject→guid 链。
- 教训：fork 在 RakPeer vtable 槽 11~42 之间有增删（NumberOfConnections 按开源槽 11 调用返回垃圾），
  开源槽位表只有被反汇编实证过的槽位才可信。

## 游戏更新后的重新校验清单

1. 重新反汇编 `cNetwork::GetNetworkStatistics`，确认偏移 `0x2B0` 与槽 `0x150/0x158`
   未变（以 `avg_ping`/`ping` 字符串引用定位该函数）。
2. 确认 `AddressOrGUID` 默认构造仍为 g@0 + index@8（0xFFFF）。
3. DLL 自身的安全网：`PN_Attach` 的 UNASSIGNED 行为校验失败时会拒绝挂接并回退
   客户端自报，不会崩服；本笔记仅用于"为什么失效"与"如何修复"。
