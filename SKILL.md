---
name: data-cleaning
description: Use when a user asks to clean, audit, or prepare tabular data (CSV/Excel/RDS/Parquet) — missing-value, duplicate, or outlier diagnosis and treatment, field/column standardization, multi-file join relationship diagnosis, cleaning logs, or data-quality reports. Prefer audit-then-clean with R tidyverse via Rscript + JSON, and a Quarto .qmd report when a report is wanted. Triggers: 数据清洗/数据审计/缺失值/重复值/异常值/字段标准化/多文件连接诊断/清洗日志/数据质量报告.
---

# data-cleaning：先审计、后清洗、可追溯交付

把「先审计 → 后清洗 → 可追溯交付」的数据清洗流程固化到 opencode + R tidyverse 工作流，执行载体为 opencode 直接调用 `Rscript`。

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
6. **用户决策点必须暂停确认**：主键不明、N:N 连接、口径冲突、异常值删除、大量缺失删除等。

## R 执行协议（本 skill 的执行基石）

opencode 在 Windows shell 中调用 R，数据经 JSON 中转、结果经 stdout 返回：

1. 用户数据（CSV 或已有表）先落到临时 JSON 文件（对象/数组，UTF-8 无 BOM）。
2. 按下方固定模板写 `.R` 脚本，`args[1]` 指向 JSON 路径，脚本内 `fromJSON` 读入。
3. `Rscript.exe --vanilla --quiet script.R input.json` 运行，**stdout 只能输出 JSON**，包启动消息用 `suppressPackageStartupMessages` 压掉。
4. 解析 stdout JSON 得到结果；诊断信息写 stderr 或日志文件，勿混入 stdout。

**Windows 铁律（必须执行）**：opencode 的 write 工具写出的是 UTF-8 **带 BOM** 文件，Rscript 对 `.R` 文件的 BOM 报 `Error: unexpected input in "﻿"`。写完后必须剥 BOM 再运行：

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

### R 风格铁律（用户长期约定，违背即返工）

- 赋值用 `=`，禁用 `<-`。
- 管道用 `|>`，禁用 `%>%`。
- 匿名函数用 `\(x)`，禁用 `function(x)`。
- 分组优先 `.by`，禁用不必要的 `group_by()`。
- 禁用 `ifelse()`、`merge()`、`gather()`、`spread()`、`*_at/*_if/*_all()`。
- **链式换行规则**：在每个 `|>`、`+`（ggplot 图层）、`&`、逻辑 OR `|` 后换行，运算符放行尾，下一行缩进对齐；一行不塞两个及以上运算符。管道链第一行放被操作对象，后续每步一行。
- `as_tibble()` 与 `suppressPackageStartupMessages()` 不可省略；`toJSON` 加 `force = TRUE` 防嵌套 list 丢字段。

## 标准工作流

### 单文件

1. 读数据，**只做结构审计，不立即清洗**。
2. 输出审计摘要：行列数、列名、类型、缺失数/率、完全重复行数、主键唯一性、数值范围、分类 Top 值、日期范围。
3. 依审计结果形成问题清单；命中「默认决策表」中需确认的高风险项（主键不明/重复、N:N、口径冲突、异常值删除、大量缺失删除）**必须暂停确认**（总原则 #6）——用户催办或一句"直接处理/别问"授权**不豁免**高风险确认；仅低风险项（全空行/列、空白文本、标准格式统一等）可按默认处理。
4. 执行清洗：列名、类型、文本、日期/数值解析、去重、缺失值、类别统一、异常值 flag。
5. 清洗后验证：前后行列数、缺失率、重复率、主键、数值范围、逻辑一致性。
6. 交付 `*_cleaned` 数据 + 清洗日志 +（需要时）质量报告 qmd。

### 多文件

1. 每个文件先独立审计。
2. 标准化列名后识别候选公共键。
3. 对候选键检查缺失率、唯一值数、重复键样例。
4. 判定关系 `1:1 / 1:N / N:1 / N:N`（模板见下）。
5. `N:N` 默认停止并提示风险；先聚合/去重/补主键再连。
6. 连接后验证行数是否膨胀、未匹配键、新增缺失、重复列后缀。

## 直接可用的片段

### 审计：结构 + 缺失 + 重复 + 异常值

```r
result = list(
  shape = list(rows = nrow(input), cols = ncol(input)),
  missing = input |>
    summarise(across(everything(), \(x) sum(is.na(x)))) |>
    pivot_longer(everything(), names_to = "column", values_to = "na_count") |>
    mutate(na_pct = round(na_count / nrow(input) * 100, 2)) |>
    arrange(desc(na_count)),
  duplicate_rows = sum(duplicated(input))
)
```

### 完全重复行诊断

```r
result = input |>
  summarise(n = n(), .by = everything()) |>
  filter(n > 1) |>
  arrange(desc(n))
```

> 用 `.by` 单次分组（不触发 dplyr 分组信息消息，避免污染 stdout JSON）；勿用 `group_by()`。

### 列名蛇形命名（需 `janitor`）

```r
result = input |>
  rename_with(\(x) janitor::make_clean_names(x, case = "snake"))
```

> 若用户环境缺 `janitor`，先询问是否安装，或退回手写列名清洗。

### 文本标准化（需 `stringr`）

```r
result = input |>
  mutate(across(where(is.character), \(x) stringr::str_squish(x))) |>
  mutate(across(where(is.character), \(x) na_if(x, "")))
```

> 缺 `stringr` 时用 base `trimws()` 降级。

### 类别标准化（`case_when` 归并）

```r
result = input |>
  mutate(member_level = case_when(
    toupper(member_level) == "VIP" ~ "VIP",
    member_level %in% c("会员", "普通会员") ~ member_level,
    TRUE ~ "普通会员"))
```

> 陷阱：`TRUE ~ "默认值"` 会把 `NA` 一并吃进去当默认值。若那不列为业务默认，请先 `mutate(member_level = if_else(is.na(member_level), NA_character_, ...))` 或用单独分支，勿让默认分支同时吞缺失。

### 日期多格式统一

```r
result = input |>
  mutate(
    date_parsed = lubridate::parse_date_time(
      date_raw,
      orders = c("Y/m/d", "Y-m-d", "Ymd"),
      quiet  = TRUE
    ) |>
      as.Date(),
    date_parse_fail = is.na(date_parsed) & !is.na(date_raw)
  )
```

> `orders` 给出所有可能格式；**保留原字段 `date_raw`，新增解析字段 `date_parsed` + 失败 flag `date_parse_fail`**（解析失败得 `NA`），不覆盖原列。

### 缺失值填补（示例，不可盲用）

```r
result = input |>
  mutate(
    across(
      where(is.numeric),
      \(x) tidyr::replace_na(x, median(x, na.rm = TRUE))
    )
  )
```

缺失处理必须结合业务含义；默认先报告缺失率，不自动填补关键字段。

### 异常值 flag（IQR，推荐默认）

```r
num_names = input |>
  select(where(is.numeric)) |>
  names()
result = input
for (nm in num_names) {
  x   = result[[nm]]
  q   = quantile(x, c(0.25, 0.75), na.rm = TRUE)
  iqr = IQR(x, na.rm = TRUE)
  result[[paste0(nm, "_outlier_flag")]] = !is.na(x) &
    (x < (q[[1]] - 1.5 * iqr) | x > (q[[2]] + 1.5 * iqr))
}
```

### 连接前关系诊断

```r
left_dup  = left |>
  count(.data[["id"]]) |>
  filter(n > 1)
right_dup = right |>
  count(.data[["id"]]) |>
  filter(n > 1)
relationship = case_when(
  nrow(left_dup) == 0 & nrow(right_dup) == 0 ~ "1:1",
  nrow(left_dup) > 0 & nrow(right_dup) == 0 ~ "N:1",
  nrow(left_dup) == 0 & nrow(right_dup) > 0 ~ "1:N",
  TRUE ~ "N:N"
)
```

多文件场景直接在单个 `.R` 脚本内用 `readr::read_csv()` 读多张表即可，不依赖单 `input`。

## 默认决策表

| 问题 | 默认处理 |
|---|---|
| 全空行/列 | 可删除，记录数量 |
| 完全重复行 | 可删除，记录数量；业务主键重复需确认 |
| 空字符串/空白文本 | 标准化为 `NA` |
| 日期解析失败 | 保留原字段，新增解析字段与失败 flag |
| 数值含单位/货币/百分号 | 解析为数值并保留或记录原始口径 |
| 类别大小写/中英/首尾空格混用 | 统一大小写 + 词典归并（`case_when`）|
| 日期多种格式混用 | `parse_date_time(orders = ...)` 统一为 `Date` |
| 主键重复（同 ID 但字段不全相同） | 保留首条 + 打标记，不静默删 |
| `case_when(TRUE ~ "默认值")` | 会把 `NA` 一并当默认值，构成业务假设——必须说清并在日志标记 |
| 缺失率高 | 不自动删除，先报告并询问 |
| 异常值 | 默认新增 flag，不删除 |
| N:N join | 默认停止，报告风险并询问 |

## 交付物规范

- **清洗数据**：原始文件名加 `_cleaned`，不覆盖原文件。
- **清洗日志**：步骤、规则、影响行列数、用户决策点。
- **质量问题报告**：优先 `.qmd`，默认 `format: typst` → 一份 PDF 文档（Quarto 内置 typst 引擎，离线可用）；仅当用户点名要幻灯片时，才用 `format: revealjs`（不依赖扩展）或 `format: quarto-talks-revealjs`（须先联网 `quarto install quarto-ext/quarto-talks`）。`.qmd` 写完后同样剥 BOM 再 `quarto render <文件>.qmd`。构建图表依赖 `ggplot2 + gridExtra`（勿依赖 `patchwork`）。骨架见同目录 `templates/清洗报告骨架.qmd`。
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
| `.qmd` 渲染失败/解析 YAML 失败 | `.qmd` 也带 BOM；`.R` 与 `.qmd` 写完后都剥 BOM 再 `quarto render` |
| "font family not found" / ggplot2 中文变方块 | 图形设备缺 CJK 字体：不要给 `theme(base_family=...)` 强加中文字体；用系统默认即可，需中文字体时用 `Sys.setlocale`/`showtext` 或 PNG 设备 |
| `(p1) \| (p2)` 报错 | 需 `patchwork`（常未装）；双图并排用 `gridExtra::grid.arrange(p1, p2, ncol = 2)` |
| revealjs/幻灯片 format 出错 | HTML 幻灯片用 `format: revealjs`；若要求 `quarto-talks-revealjs`，须先联网装扩展 `quarto add quarto-ext/quarto-talks`，否则渲染报 "Unable to read the extension" |

## 自检清单

- [ ] 每个输入文件是否已分别审计？
- [ ] 多文件是否已诊断连接键与连接关系？
- [ ] 是否避免了未诊断的 `N:N join`？
- [ ] 是否验证连接后行数膨胀与未匹配键？
- [ ] 是否保留原始数据且另存清洗结果？
- [ ] 异常值是否默认 flag 而非盲删？
- [ ] 是否记录清洗日志与用户决策点？
- [ ] 业务假设（如 `case_when` 默认值补缺）是否在日志中显式标注？
- [ ] 是否生成清洗后验证摘要？
- [ ] R 代码是否遵守 `=`、`|>`、`\(x)`、`.by`？
- [ ] `.R` / `.qmd` 文件是否剥 BOM、stdout 是否只输出 JSON？
