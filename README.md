# WOWForever-oldma-Questie-CN

《魔兽世界：无限》（暴雪官方国服 zhCN 客户端，1.60.1 / Interface 16001）用的 **QuestieDB 中文运行时补全插件**。

Questie / QuestieDB 自带中文语料，但"无限"新增的一批任务、物品、NPC 没有对应中文词条，于是地图提示、鼠标提示里会冒出英文。本插件把这些缺口补成中文——**它不翻译任何文本**，只读取客户端自己已经拥有的官方中文数据，再注入 QuestieDB 的本地化层。任何客户端拿不到的条目保持英文，绝不机器翻译或编造。

> 仓库名是 `WOWForever-oldma-Questie-CN`，但**插件目录必须叫 `QuestieCN_Runtime`**（与 `.toc`、SavedVariables 名称绑定），安装时不要改名。

---

## 快速开始

1. 下载 [Releases](../../releases) 里的 `WOWForever-oldma-Questie-CN-v1.0.0.zip`（或直接用仓库 `dist/` 下的同名压缩包）。
2. 解压，把里面的 **`QuestieCN_Runtime`** 整个文件夹放进：

   ```
   D:\World of Warcraft\_forever_\Interface\AddOns\
   ```

   最终路径应为 `...\AddOns\QuestieCN_Runtime\QuestieCN_Runtime.toc`。
3. 进游戏，在插件列表勾选 **「Questie 中文运行时补全」**（依赖 `QuestieDB`，请一并启用），然后 `/reload`。
4. 聊天框出现 `QuestieCN 已启用：待补全任务 …` 即成功。

卸载：取消勾选或删除 `QuestieCN_Runtime` 文件夹即可，**不会修改 Questie / QuestieDB 的任何原文件**。

### 运行环境

| 项目 | 要求 |
| --- | --- |
| 客户端 | 《魔兽世界：无限》国服 zhCN（1.60.1.x，Interface 16001） |
| 依赖 | `QuestieDB`（强依赖）、`Questie`（实际使用方） |
| 语言 | `GetLocale() == "zhCN"`；兼容 `DF_CNLocale` 的强制中文开关 |
| 存档 | `QuestieCN_RuntimeDB`（SavedVariables，自动创建） |

英文客户端下插件静默不工作。

---

## 它是怎么工作的

1. **找缺口**：`Gaps.lua` 由 QuestieDB 的 baked TOC（`X-l10n-zhCN-*` CBOR 列块）离线解码生成，列出所有缺中文的实体 ID（任务名 706、任务目标文本 1448、物品名 6203、NPC 名 5447、物件名 6077）。
2. **运行时学中文**（后台限速，不卡登录）：
   - `C_QuestLog.GetQuestObjectives(id)` 触发客户端向服务器预取任务数据（Questie 自己的 `QuestLinks/ChatFilter.lua` 也这么做），随后用 `HaveQuestData` / `GetTitleForQuestID` / `GetQuestObjectives` 读取官方中文；
   - `C_TooltipInfo.GetHyperlink("quest:<id>:0")` 取原生中文任务标题与 `QuestObjective` 行；
   - 任务日志（`QUEST_LOG_UPDATE` / `QUEST_ACCEPTED`）直接提供已接任务的官方中文；
   - `C_Item.GetItemNameByID`、原生 Unit / Item / GameObject tooltip 学物品、NPC、物件名；
   - `C_Map.GetAreaInfo(areaID)` 把 Questie 的英文 `l10n.zoneLookup` 换成官方中文区域名。
   - **只有含中文的字符串才会被收录**，英文一律丢弃。
3. **注入**：通过公开的 `LibQuestieDB.l10n.SetCorrection()` 写入本地化修正层（优先级高于实体数据），并让 QuestieDB 的实体缓存失效。
4. **缓存**：学到的中文写入 SavedVariables，下次登录开服即生效，越玩越全。
5. **静态补表**（可选）：`Static.lua` 里 5 条中文原样引自 [新手盒子·魔兽世界无限数据库](https://wowforever.wclbox.com/)，仅用于客户端明确拒绝下发的任务；它不覆盖运行时学到的中文，删除该文件并从 `.toc` 去掉对应一行即可停用。

---

## 命令

| 命令 | 作用 |
| --- | --- |
| `/qcn` | 查看进度：已学数量、剩余队列、被拒绝数量、静态补表数量 |
| `/qcn missing` | 列出仍缺中文的任务，分「服务端拒绝 / 待重试 / 仅缺目标文本」三类，完整清单写入 `QuestieCN_RuntimeDB.missingReport` |
| `/qcn scan` | 清空拒绝记录并重建队列，强制重试全部缺口 |
| `/qcn zones` | 立即用客户端官方区域名重刷地图/区域名 |
| `/qcn pause` / `/qcn resume` | 暂停 / 恢复后台学习（已缓存中文仍生效） |
| `/qcn reset` | 清空学习缓存，`/reload` 后重新学习 |

---

## 常见问题

**装完还有英文？**
先 `/reload`——运行时注入后，Questie 已经渲染过的提示可能不会自动重建。重载后仍是英文，说明该条目确实没有中文数据。

**为什么有些任务永远补不上？**
看 `/qcn missing`。客户端日志（`Logs/QuestCache.log`）里会出现 `r=HaveDataQuery QuestieCN_Runtime` 紧接 `Deny`，表示服务器拒绝下发该任务数据。这类多是传承奖励、教学、坐骑/专业引导等**条件任务**，未满足条件时连官方中文都不存在；等你真正接到任务时，任务日志会自动把它学会。`Static.lua` 补了资料站能查到的 5 条，其余 11 条连中文资料站都是 404，只能保持英文。

**为什么任务名是中文、目标描述还是英文？**
客户端给了标题但没给目标文本。插件会从任务链接 tooltip 的 `QuestObjective` 行继续补；若官方数据本身没有，就保持英文，不会自行翻译。

**物品 / NPC 名怎么补得慢？**
大量"无限"新增物品是服务器缓存物品，本地 DB2 查不到，只能靠鼠标悬停原生 tooltip 逐步学习；NPC 与物件名同样如此。玩得越久覆盖越广。

**会不会拖慢游戏 / 刷服务器请求？**
任务预取限速每 0.5 秒 4 个、并发上限 12；物品名只读本地 API；注入每 1.5 秒最多一次。区域名在登录后 0.5 秒扫一次并缓存。不会向服务器批量轰炸。

---

## 目录结构

```
WOWForever-oldma-Questie-CN/
├── README.md                      本说明
├── LICENSE                       MIT（本仓库原创代码）
├── QuestieCN_Runtime/             插件本体（直接放进 AddOns）
│   ├── QuestieCN_Runtime.toc
│   ├── Core.lua                   运行时学习 + 注入 + 命令
│   ├── Gaps.lua                   缺中文实体 ID 清单（自动生成）
│   └── Static.lua                 可选静态中文补表（自动生成）
├── dist/                          打包好的 zip
└── tools/                         离线再生成 / 自检脚本
    ├── qdb_probe.py               base64 → zlib → CBOR 解码 TOC 元数据
    ├── qdb_gen_gaps.py            生成 Gaps.lua
    ├── qdb_fetch_static.py        抓取中文资料站生成 Static.lua
    └── qdb_sim_test.py            用 lupa 模拟 WoW 环境做冒烟测试
```

### 从源码重新生成（QuestieDB 更新后）

```bash
pip install lupa
python tools/qdb_gen_gaps.py        # 读已安装的 QuestieDB_Forever.toc → 更新 Gaps.lua
python tools/qdb_fetch_static.py    # 读本地 SavedVariables + 中文资料站 → 更新 Static.lua
python tools/qdb_sim_test.py        # 校验语法与运行流程
```

脚本默认路径指向 `D:\World of Warcraft\_forever_\...`，换机器时改脚本顶部的常量即可。`SMOKE TEST PASSED` 表示编译、启动、注入、拒绝记录、二次登录缓存全部通过。

---

## 数据来源与许可

- 本仓库的 Lua / Python 代码为原创，采用 **MIT** 许可（见 `LICENSE`）。
- `Gaps.lua` 是从 [QuestieDB](https://github.com/Travnick/QuestieDB)（GPL-3.0）安装包的 TOC 元数据中离线提取的**实体 ID 与缺口标记**，不含其代码或文本内容；与 QuestieDB 一同再分发时请遵守其许可。
- `Static.lua` 中的中文文本原样引自 [新手盒子·魔兽世界无限数据库](https://wowforever.wclbox.com/)（其任务文本来自官方 zhCN 客户端 / Wowhead 无限数据库），**不是本项目翻译**。
- 游戏内一切任务、物品、区域名称与文本版权归暴雪娱乐所有。

本项目是非官方第三方插件，与暴雪娱乐、Questie / QuestieDB 及上述资料站均无隶属关系。
