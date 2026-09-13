---
name: data-cleaning
description: >-
  Use when a user asks to clean, audit, or prepare tabular data (CSV/Excel/RDS/Parquet) —
  missing-value, duplicate, or outlier diagnosis and treatment, field/column standardization,
  multi-file join relationship diagnosis, cleaning logs, or data-quality reports.
  Prefer audit-then-clean with R tidyverse via Rscript + JSON, and a Quarto .qmd report when
  a report is wanted.
  Triggers: 数据清洗/数据审计/缺失值/重复值/异常值/字段标准化/多文件连接诊断/清洗日志/数据质量报告.
related-skills:
  - tidy-data
compatibility: claude-code, zcode, opencode, codex
---

# data-cleaning：先审计、后清洗、可追溯交付

把「先审计 → 后清洗 → 可追溯交付」的数据清洗流程固化到 Agent + R tidyverse 工作流，执行载体为 Agent 在 shell 中直接调用 `Rscript`（兼容 Claude Code / ZCode / OpenCode / Codex 等 Skill 运行时）。

## When to Use / Not

**Use**：CSV/Excel/RDS/Parquet 等表格数据的结构审计、缺失/重复/异常值诊断与处理、列名与字段标准化、文本/日期/数值解析、多文件连接关系诊断、清洗日志与质量报告生成。

**Not**：
- 完整 RStudio 交互式分析（本 skill 走脚本批处理，不替代交互探索）。
- 自动决定高风险业务规则（口径冲突、删行、N:N 连接必须让用户拍板）。
- 超大文件（约 >200MB）：先建议 CSV/Parquet 中转或独立 R 脚本，不要硬塞进 JSON 往返。

## 总原则（优先于任何具体代码）

1. **先审计，后清洗**：没有结构/缺失/重复/异常概览，不直接改数据。
2. **先诊断连接关系，再 join**：多文件必须先判断 `1:1 / 1:N / N:1 / N:N`，禁止盲目 `left_join()`。
3. **原始数据不可覆盖**：清洗结果另存为 `*_cleaned` 后缀或输出目录，永不覆盖原文件。
4. **异常值默认标记，不盲删**：默认新增 `*_outlier_flag`；删除/截尾必须说明规则与影响行数。
5. **可追溯**：记录每一步的规则、原因、影响行列数、输出文件。
6. **用户决策点必须暂停确认**：主键不明、N:N 连接、口径冲突、异常值删除、大量缺失删除等。唯一出口：用户**书面坚持**且明知后果时，按其决策执行并在日志"用户决策"列标记 `用户强制`，全程可追溯；唯独**覆盖原始文件**绝对拒绝。

## R 执行协议（本 skill 的执行基石）

Agent 在 Windows shell 中调用 R，数据经 JSON 中转、结果经 stdout 返回：

1. 数据进入脚本的两条路：对话中内联的表（粘贴数据/内存对象）落临时 JSON 文件（对象/数组，UTF-8 无 BOM），脚本经 `args[1]` 读入；磁盘上已有的文件（CSV/Excel/RDS/Parquet）**不经 JSON 中转**，脚本内直接 `read_any()` 按路径读入，JSON 只传文件路径清单。
2. 按下方固定模板写 `.R` 脚本，`args[1]` 指向 JSON 路径，脚本内 `fromJSON` 读入。
3. `Rscript.exe --vanilla --quiet script.R input.json` 运行，**stdout 只能输出 JSON**，包启动消息用 `suppressPackageStartupMessages` 压掉。
4. 解析 stdout JSON 得到结果；诊断信息写 stderr 或日志文件，勿混入 stdout。

**Windows 铁律（必须执行）**：部分 Agent 运行时的 write 工具（如 OpenCode）写出 UTF-8 **带 BOM** 文件，Rscript 对 `.R` 文件的 BOM 报 `Error: unexpected input in "﻿"`。只要见到该报错，或确认所用运行时会写 BOM，写完后必须剥 BOM 再运行：

```powershell
$c = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($p, $c, $utf8NoBom)
```

输入 JSON 与输出结果都可能含中文，保持 UTF-8 无 BOM 全链路。

### 固定 R 模板（每次都在其内填空）

```r
suppressPackageStartupMessages({
  library(jsonlite)
  library(tidyverse)
})
args  = commandArgs(trailingOnly = TRUE)
input = as_tibble(jsonlite::fromJSON(args[1]))
# ... 中间放清洗代码，最终必须创建 result 对象 ...
result = input |>
  summarise(n = n())
cat(jsonlite::toJSON(result, auto_unbox = TRUE, pretty = FALSE, force = TRUE))
```

### 磁盘文件版模板（数据在磁盘上时，JSON 只传路径清单）

```r
suppressPackageStartupMessages({
  library(jsonlite)
  library(tidyverse)
})
args  = commandArgs(trailingOnly = TRUE)
paths = jsonlite::fromJSON(args[1])$files   # 如 {"files": ["data/orders.csv", "data/customers.csv"]}
input = read_any(paths[1])                  # read_any 见 references/snippets.md；多文件各自读入
# ... 中间放清洗代码，最终必须创建 result 对象 ...
cat(jsonlite::toJSON(result, auto_unbox = TRUE, pretty = FALSE, force = TRUE))
```

### R 风格铁律（用户长期约定，违背即返工）

- 赋值用 `=`，禁用 `<-`。
- 管道用 `|>`，禁用 `%>%`。
- 匿名函数用 `\(x)`，禁用 `function(x)`。
- 分组优先 `.by`，禁用不必要的 `group_by()`。
- 禁用 `ifelse()`、`merge()`、`gather()`、`spread()`、`*_at/*_if/*_all()`。
- **链式换行规则**：在每个 `|>`、`+`（ggplot 图层）、`&`、逻辑 OR `|` 后换行，运算符放行尾，下一行缩进对齐；一行不塞两个及以上运算符。管道链第一行放被操作对象，后续每步一行。
- `as_tibble()` 与 `suppressPackageStartupMessages()` 不可省略；`toJSON` 加 `force = TRUE` 防嵌套 list 丢字段。

> 铁律与 `tidy-data` 技能 §9 同源（`=`、`|>`、`\(x)`、`.by`、禁 `ifelse`/`merge`/`%>%`/旧 scoped 变体）。两处任一改动，必须双向同步；本文件的链式换行规则与 JSON 协议条款为本 skill 特有追加。

## 标准工作流

### 单文件
1. 读数据，**只做结构审计，不立即清洗**。
2. 输出审计摘要：行列数、列名、类型、缺失数/率、完全重复行数、主键唯一性、数值范围、分类 Top 值、日期范围，外加**结构探测**（汇总行混入、分组列仅首行有值、文本污染数值列——见片段"结构探测"）。
3. 依审计结果形成问题清单；命中「默认决策表」中需确认的高风险项（主键不明/重复、N:N、口径冲突、异常值删除、大量缺失删除）**必须暂停确认**（总原则 #6）——用户催办或一句"直接处理/别问"授权**不豁免**高风险确认；仅低风险项（全空行/列、空白文本、标准格式统一等）可按默认处理。
4. 执行清洗：列名、类型、文本、日期/数值解析、去重、缺失值、类别统一、异常值 flag。
5. 清洗后验证：前后行列数、缺失率、重复率、主键、数值范围、逻辑一致性。
6. 交付 `*_cleaned` 数据 + 清洗日志 +（需要时）质量报告 qmd。

### 多文件

1. 每个文件先独立审计。
2. 标准化列名后识别候选公共键。
3. 对候选键做**五查**：缺失率、唯一值数、重复键样例、**类型一致**（numeric vs character）、**格式规范**（前导零/空格/大小写）——片段"键一致性检查"。
4. 判定关系 `1:1 / 1:N / N:1 / N:N`（模板见下）。
5. join 选型正向规则：`N:1` → `left_join(明细, 维表)`；`1:1` → 任一方向；`1:N` → 先想清以哪侧为基准（通常明细为主）；`N:N` 默认停止并提示风险，先聚合/去重/补主键再连。
6. 连接后验证：行数膨胀、**双向未匹配（`anti_join`）**、新增缺失、重复列后缀、**键映射抽样核对**（防"错误匹配"，不只防"全不匹配"）。未匹配 > 0 时回五查 + `match_rate` 对比（`match_norm > match_raw` 即大小写/空格不一致实锤）。

## 技能协作（reshape / 分组 / 累计范式兜底）

清洗常涉及结构转换与分组计算，本 skill 专注"审计—清洗—交付"；**需要 reshape / 分组 / 累计等数据思维时，加载 `tidy-data` 技能取 8 范式代码兜底**：

- 宽表按主键折叠 / 长宽互转 → tidy-data 范式1（`pivot_longer` / `pivot_wider`）；
- 按组清洗（组内填充、组内去重、组级筛全缺失组）→ 范式2 / 3 / 4；
- 行数变化的分组变换（按组连接 / 建模 / 读文件）→ 范式5 `nest + map`；
- 累计 / 滚动（累计去重、滚动去异常）→ 范式6 `accumulate` / 范式7 `slide`；
- 非等连接（时间窗口 join、档位匹配）→ 范式8 `join_by(closest)`。

两 skill 的 R 铁律一致（`=`、`|>`、`\(x)`、`.by`、禁 `ifelse`/`merge`），无冲突；审计与清洗主流程仍以本 skill 为准。

## 直接可用的片段（完整代码在 [references/snippets.md](references/snippets.md)）

片段已全部下沉到 `references/snippets.md`，用时按下表取用，不要凭记忆重写：

| 场景 | 片段 | 备注 |
|---|---|---|
| 结构/缺失/重复/异常概览 | 审计：结构+缺失+重复+异常值 | 一次输出审计摘要 |
| 完全重复行定位 | 完全重复行诊断 | `.by` 单次分组，勿 `group_by` |
| 列名标准化 | 列名蛇形命名 | 需 `janitor`；缺则手写降级 |
| 文本清洗 | 文本标准化 | 需 `stringr`；缺则 `trimws()` 降级 |
| 类别归并 | 类别标准化（case_when） | `TRUE ~` 默认分支吞 NA 陷阱 |
| 日期多格式 | 日期多格式统一 | 保留原列 + 失败 flag |
| 缺失决策与填补 | 缺失决策线（三档） | <5% 可填补 / 5–40% 询问 / >40% 或关键列拍板 |
| 异常值标记 | 异常值 flag（三法并列） | 默认 IQR；重尾/小样本用 MAD；正态大样本可用 z-score |
| 多格式读取 | 多格式读取 read_any | CSV/Excel/RDS/Parquet；需 `readxl`/`arrow`；CSV 默认走 `read_csv_anyenc` 判码 |
| 清洗日志 | 结构化清洗日志 | 每步一行，高风险项记用户决策 |
| 连接关系判定 | 连接前关系诊断 | 输出 1:1 / N:1 / 1:N / N:N；附键一致性五查与连接后验证 |
| 中文业务格式 | 金额/中文日期/全角转半角 | "1,234.50元"、`Y年m月d日`、全角 `chartr`；禁直接 as.numeric |

多文件场景在单个 `.R` 脚本内用 `read_any()` 按扩展名读入多张表，不依赖单 `input`。

## 默认决策表

| 问题 | 默认处理 |
|---|---|
| 全空行/列 | 可删除，记录数量 |
| 完全重复行 | 可删除，记录数量；业务主键重复需确认 |
| 空字符串/空白文本 | 标准化为 `NA` |
| 日期解析失败 | 保留原字段，新增解析字段与失败 flag |
| 数值含单位/货币/百分号 | 解析为数值并保留或记录原始口径 |
| 类别大小写/中英/首尾空格混用 | 统一大小写 + 词典归并（`case_when`）|
| 日期多种格式混用 | Y-M-D 族（含中文"2023年1月5日"、紧凑 `20230108`）直接 `ymd()`；顺序不同（dmy/mdy）才用 `parse_date_time(orders = ...)`，中文写 `"Y年m月d日"` |
| 主键重复（同 ID 但字段不全相同） | 保留首条 + 打标记，不静默删 |
| `case_when(TRUE ~ "默认值")` | 会把 `NA` 一并当默认值，构成业务假设——必须说清并在日志标记 |
| 缺失率 < 5%（非关键列） | 可默认填补（数值=中位数、分类=众数），日志记录填补口径 |
| 缺失率 5%–40% | 保留 NA，报告缺失率并询问处理方式 |
| 缺失率 > 40%，或关键列（主键/标识/核心业务字段）缺失 | 不填补不删除，列清单交用户拍板 |
| 汇总行混在明细（"总计/小计/合计"行） | 审计阶段识别并**剥离后再清洗**，记录剔除行数 |
| 分组列仅组首行有值（Excel 合并单元格导出） | **结构性缺失**：`tidyr::fill()` 按序继承（先确认"空=继承上一行"语义），**不进缺失三档线**，日志记录填充范围 |
| 异常值 | 默认新增 flag（默认 IQR；重尾/小样本用 MAD，正态大样本可用 z-score），不删除 |
| N:N join | 默认停止，报告风险并询问 |
| 连接键类型/格式不一致（一边 123，一边 "00123"） | 统一转 character 再比对；**前导零是否有业务语义必须问用户**（静默 `as.numeric()` 会合并不同实体且不报错）；连接后抽样核对键映射 |

## 交付物规范

- **清洗数据**：原始文件名加 `_cleaned`，不覆盖原文件。
- **清洗日志**：步骤、规则、影响行列数、用户决策点。
- **质量问题报告**：优先 `.qmd`，默认 `format: PrettyTypst-typst` → 一份 PDF 文档（Quarto 扩展已 vendor 在 `_extensions/PrettyTypst/`，离线可用；字体链 Ubuntu → Microsoft YaHei → PingFang SC → Noto Sans CJK SC，中文跨平台确定性渲染）。**渲染布局：把 `_extensions/` 整个复制到报告工作目录、与实例化后的 `.qmd` 同级再渲染**（Quarto 在含点开头的目录如 `.zcode` 下不做向上扩展发现；同目录布局全环境可用）。仅当用户点名要幻灯片时，才用 `format: revealjs`（不依赖扩展）。渲染规则：**Git Bash 下先 `env -u LC_CTYPE -u LANG -u LC_ALL quarto render <文件>.qmd`**（LC_CTYPE=C.UTF-8 使 R 启动 locale 切换失败，chunk 内中文被转义成 `<U+XXXX>` 而解析报错）；PowerShell/cmd 直接 `quarto render`。`.qmd` 写完后同样剥 BOM。构建图表依赖 `ggplot2 + gridExtra`（勿依赖 `patchwork`）。骨架见 `templates/cleaning_report_skeleton.qmd`，真实数据实例见 `examples/cleaning_report.qmd`。注：SkillHub 分发包按平台校验裁剪（平台禁止二进制与 .R 脚本上传，纯文档发行）——报告模板、vendored 扩展、端到端示例、16 项回归脚本与展示图完整版以 GitHub 仓库为准。
- **问题清单**：主键不明、N:N 风险、口径冲突、异常值策略、需人工确认的类别映射。
- **数据字典**：字段名、类型、含义、取值范围、缺失率、清洗规则。

## 常见坑（Common Mistakes）

| 症状 | 原因与解法 |
|---|---|
| `Error: unexpected input in "﻿"` | `.R` 文件带 UTF-8 BOM；先剥 BOM 再运行 |
| stdout JSON 解析失败 | 包启动消息污染 stdout；检查 `suppressPackageStartupMessages` 与 `cat(toJSON(...))` 是否为唯一 stdout 输出 |
| `list`/`data.frame` 结构异常 | 漏了 `as_tibble()`；`fromJSON` 对简单对象返回结构不统一 |
| 嵌套 list 字段丢失 | `toJSON` 缺 `force = TRUE` |
| 中文乱码 | 任一环节用了非 UTF-8（如 PowerShell `Out-File` 默认编码）；全程 UTF-8 无 BOM |
| `.qmd` 渲染失败/R chunk 报 `unexpected '<'`（代码里出现 `<U+XXXX>`） | Git Bash 的 `LC_CTYPE=C.UTF-8` 使 R 启动 locale 切换失败，knitr 把 chunk 内中文转义；`env -u LC_CTYPE -u LANG -u LC_ALL quarto render` 或改用 PowerShell/cmd |
| `.qmd` 渲染失败/解析 YAML 失败 | `.qmd` 也带 BOM；`.R` 与 `.qmd` 写完后都剥 BOM 再 `quarto render` |
| "font family not found" / ggplot2 中文变方块 | 图形设备缺 CJK 字体：不要给 `theme(base_family=...)` 强加中文字体；用系统默认即可，需中文字体时用 `Sys.setlocale`/`showtext` 或 PNG 设备 |
| `(p1) \| (p2)` 报错 | 需 `patchwork`（常未装）；双图并排用 `gridExtra::grid.arrange(p1, p2, ncol = 2)` |
| `list.files()` 找不到明知存在的文件 | locale 非 UTF-8 时（R 启动报 `Setting LC_CTYPE=C.UTF-8 failed`）中文文件名条目被静默丢弃；脚本/模板一律用 ASCII 文件名，或改用 `file.exists()`/`Sys.glob()` 定位 |
| 中文 CSV 读入后是 `\xd0\xd5` 式乱码 | 源文件是 GBK（Excel/老系统导出），且 `readr` **不报错而是静默保留原始字节**：用片段 `read_csv_anyenc` 读前判码（`validUTF8` 检查文件头），按 GB18030 读入，并在清洗日志记录源编码 |
| 异常检测/数值处理无声失效 | 汇总行混入使数值列被猜成 character，`where(is.numeric)` **静默跳过**该列（不报错）——清洗前先跑类型断言（片段"结构探测"），确认每列真实类型 |
| `filter(!if_any(...))` 静默丢行 | `if_any` 的 NA 会传播：所选列存在 NA 且其余列不匹配时整行按 FALSE 丢弃；取反检测必须先 `coalesce(x, "")` 兜底（见片段"结构探测"） |
| revealjs/幻灯片 format 出错 | HTML 幻灯片用 `format: revealjs`；若要求 `quarto-talks-revealjs`，须先联网装扩展 `quarto add quarto-ext/quarto-talks`，否则渲染报 "Unable to read the extension" |

## 自检清单

- [ ] 每个输入文件是否已分别审计？
- [ ] 数值处理前是否已排除汇总行、合并单元格、类型污染等结构问题？
- [ ] 多文件是否已诊断连接键与连接关系？键是否做了类型/前导零一致性检查？
- [ ] 是否避免了未诊断的 `N:N join`？
- [ ] 是否验证连接后行数膨胀与未匹配键？
- [ ] 是否保留原始数据且另存清洗结果？
- [ ] 异常值是否默认 flag 而非盲删？
- [ ] 是否记录清洗日志与用户决策点？
- [ ] 业务假设（如 `case_when` 默认值补缺）是否在日志中显式标注？
- [ ] 是否生成清洗后验证摘要？
- [ ] R 代码是否遵守 `=`、`|>`、`\(x)`、`.by`？
- [ ] `.R` / `.qmd` 文件是否剥 BOM、stdout 是否只输出 JSON？
