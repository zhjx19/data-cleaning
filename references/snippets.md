# data-cleaning 可复用片段集

> 本文件是 SKILL.md「直接可用的片段」的完整载体，按场景表取用。
> 所有片段遵守 R 铁律（`=`、`|>`、`\(x)`、`.by`、禁 `ifelse`/`merge`）；
> `input` 均指 R 执行协议固定模板中从 JSON 读入的 tibble。

## 审计：结构 + 缺失 + 重复 + 异常值

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

## 完全重复行诊断

```r
result = input |>
  summarise(n = n(), .by = everything()) |>
  filter(n > 1) |>
  arrange(desc(n))
```

> 用 `.by` 单次分组（不触发 dplyr 分组信息消息，避免污染 stdout JSON）；勿用 `group_by()`。

## 列名蛇形命名（需 `janitor`）

```r
result = input |>
  rename_with(\(x) janitor::make_clean_names(x, case = "snake"))
```

> 若用户环境缺 `janitor`，先询问是否安装，或退回手写列名清洗。

## 文本标准化（需 `stringr`）

```r
result = input |>
  mutate(across(where(is.character), \(x) stringr::str_squish(x))) |>
  mutate(across(where(is.character), \(x) na_if(x, "")))
```

> 缺 `stringr` 时用 base `trimws()` 降级。

## 类别标准化（`case_when` 归并）

```r
result = input |>
  mutate(member_level = case_when(
    toupper(member_level) == "VIP" ~ "VIP",
    member_level %in% c("会员", "普通会员") ~ member_level,
    TRUE ~ "普通会员"))
```

> 陷阱：`TRUE ~ "默认值"` 会把 `NA` 一并吃进去当默认值。若那不列为业务默认，请先 `mutate(member_level = if_else(is.na(member_level), NA_character_, ...))` 或用单独分支，勿让默认分支同时吞缺失。

## 日期多格式统一

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

## 缺失决策线（先量化，再按档处理）

> 三档线（先 `na_tbl` 看全貌，再按档处理）：`<5%` 非关键列可默认填补；
> `5%–40%` 保留 NA 并询问；`>40%` 或关键列（主键/标识/核心业务字段）交用户拍板。

```r
# 结构缺失探针：一列的 NA 全部紧跟在非 NA 后 = 合并单元格样式（合并单元格导出的典型形态）
is_structural_na = \(x) {
  idx = which(is.na(x))
  length(idx) > 0 && all(idx > 1) && all(!is.na(x[idx - 1]))
}

na_tbl = input |>
  summarise(across(everything(), \(x) mean(is.na(x)))) |>
  pivot_longer(everything(), names_to = "column", values_to = "na_rate") |>
  mutate(
    structural = vapply(input, is_structural_na, logical(1))[column],
    band = case_when(
      structural      ~ "structural-fill",  # 结构性缺失 → fill() 继承，不进三档线
      na_rate <  0.05 ~ "impute-ok",        # 非关键列可默认填补
      na_rate <= 0.40 ~ "ask",              # 报告并询问
      TRUE            ~ "flag-drop"         # 标记待删/待补，用户拍板
    ))
```

低档填补示例（**仅非关键列**，把 `<非关键数值列>` 换成实际列名；填补口径写进日志）：

```r
result = input |>
  mutate(across(<非关键数值列>, \(x) tidyr::replace_na(x, median(x, na.rm = TRUE))))
```

关键字段（主键、核心金额/数量）任何缺失率都不自动填补——填补是业务假设。

## 异常值 flag（三法并列，默认 IQR）

> 选型：**IQR** 默认（无分布假设；小样本 <10 会被极端值自身撑大）；**MAD** 稳健 z 分数
> （重尾、被极值污染、小样本时首选）；**z-score**（数据近似正态且 n 较大时）。
> 多维联合离群（Mahalanobis）超出本 skill 范围，需要时转专门统计流程。
> `across(.names = )` 原生逐列命名，**无需 for 循环**。

```r
flag_outlier_iqr = \(x) {
  q = quantile(x, c(0.25, 0.75), na.rm = TRUE)
  i = IQR(x, na.rm = TRUE)
  !is.na(x) & (x < q[[1]] - 1.5 * i | x > q[[2]] + 1.5 * i)
}
flag_outlier_zscore = \(x, z = 3) {
  m = mean(x, na.rm = TRUE); s = sd(x, na.rm = TRUE)
  !is.na(x) & abs((x - m) / s) > z
}
flag_outlier_mad    = \(x, k = 3.5) {  # R 的 mad() 已含 1.4826 常数
  med = median(x, na.rm = TRUE); m = mad(x, na.rm = TRUE)
  !is.na(x) & abs(x - med) / m > k
}

result = input |>
  mutate(across(where(is.numeric), flag_outlier_iqr, .names = "{.col}_outlier_flag"))
```

## 结构探测：汇总行 / 合并单元格 / 类型污染（清洗前先跑）

> 结构问题不是"脏值"，是**行/类型层面的结构性污染**——不进缺失三档线，先探测、再剥离/继承。

```r
# 1) 疑似汇总行：关键文本列命中 总计/小计/合计/Total
#    ⚠ 取反过滤必须先 coalesce(x, "")：if_any 的 NA 会传播，filter 把 NA 行当 FALSE
#    整行静默丢弃（Region 为 NA 的正常数据行会被误删）
sum_rows = input |>
  filter(if_any(where(is.character), \(x) str_detect(str_squish(x), "^(总计|小计|合计|Total)$")))
# 命中：先剥离（保留原文件可复核、记录剔除行数），再做任何数值统计
clean = input |>
  filter(!if_any(where(is.character),
                 \(x) str_detect(str_squish(coalesce(x, "")), "^(总计|小计|合计|Total)$")))

# 2) 类型断言：数值列被猜成 character 的典型信号（汇总行/带单位文本混入）
#    where(is.numeric) 会【静默跳过】character 列——先断言类型，再上 across/异常检测
type_tbl = input |>
  summarise(across(everything(), \(x) class(x)[1])) |>
  pivot_longer(everything(), names_to = "column", values_to = "class")

# 3) 合并单元格隐式填充：分组列仅组首行有值 = 结构性缺失，用 fill() 按序继承
result = input |> tidyr::fill(地区, .direction = "down")
# 前提：与用户确认"空 = 继承上一行"这一业务语义；日志记录填充列与影响范围
```

## 中文业务格式解析（金额 / 日期 / 全角）

> 决策表"数值含单位/货币/百分号"与"日期多种格式混用"两行的中文场景代码。
> 坑：直接 `as.numeric("1,234.50元")` **不报错、全列变 NA**（仅警告），必须先解析。

```r
# 金额："1,234.50元"、"¥2,058"、"342.35元"、"-120" → 数值
# parse_number 无惧千分位与前后缀（元/¥都行）；对比 as.numeric("342.35元") = NA
result = input |>
  mutate(
    revenue_raw = as.character(金额),
    revenue_num = readr::parse_number(revenue_raw),
    revenue_parse_fail = is.na(revenue_num) & !is.na(revenue_raw)
  )

# 中文日期："2023年1月5日" 混在数字格式里——ymd() 一发全吃（年月日/斜杠/横杠/紧凑，
# 直接返回 Date）。仅当顺序不是 Y-M-D（如 dmy/mdy）或部分日期（只到月）才用
# parse_date_time(orders = c(...))，orders 里中文写 "Y年m月d日"。
result = input |>
  mutate(
    date_raw = 日期,
    date = ymd(date_raw),
    date_parse_fail = is.na(date) & !is.na(date_raw)
  )

# 全角数字/字母 → 半角（base chartr，无 stringi 依赖）；转换后再做数值解析
to_half = \(x) chartr(
  "０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ",
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
  x)
result = input |> mutate(金额 = to_half(as.character(金额)))
```

## 多格式读取（CSV / Excel / RDS / Parquet）

多文件场景直接在 `.R` 脚本内按扩展名读入多张表，不依赖单 `input`（需 `readxl` / `arrow`）：

```r
read_any = \(path) {
  ext = tolower(tools::file_ext(path))
  out = switch(ext,
    csv     = read_csv_anyenc(path),   # 中文 CSV 自动判码（GBK 静默乱码防护，见下）
    xlsx    = readxl::read_excel(path),
    xls     = readxl::read_excel(path),
    rds     = readRDS(path),
    parquet = arrow::read_parquet(path),
    stop("不支持格式: ", path))
  as_tibble(out)
}
left  = read_any("data/orders.xlsx")
right = read_any("data/customers.parquet")
```

> 缺 `readxl` / `arrow` 时先询问是否安装，或退回 CSV 中转。

### 中文 CSV 乱码防护（GBK/GB18030 判码）

Excel 或老系统导出的中文 CSV 常是 GBK 编码。**`readr` 默认读它不报错，而是静默保留
原始字节**（`\xd0\xd5` 式乱码），事后无法发现——必须读前判码：

```r
read_csv_anyenc = \(path) {
  # 读文件头 1MB 判码：合法 UTF-8 或纯 ASCII → 默认读；否则按 GB18030（GBK 超集）读
  b    = readBin(path, "raw", n = 1000000)
  utf8 = validUTF8(rawToChar(b))
  if (utf8 || !any(b > as.raw(0x7f))) {
    readr::read_csv(path, show_col_types = FALSE)
  } else {
    readr::read_csv(path, locale = readr::locale(encoding = "GB18030"),
                    show_col_types = FALSE)
  }
}
```

> 判定结果与源编码一并写入清洗日志。

## 结构化清洗日志（可追溯的最后一环）

```r
# 每步清洗 append 一行，最终输出 cleaning_log.csv（步骤/规则/前后行数/影响/用户决策点）
cleaning_log = tibble(
  步骤     = character(),
  规则     = character(),
  前行数   = integer(),
  后行数   = integer(),
  影响     = character(),
  用户决策 = character()
)
cleaning_log = add_row(cleaning_log,
  步骤 = "删除完全重复行", 规则 = "两行全同删除",
  前行数 = nrow(input), 后行数 = nrow(distinct(input)),
  影响 = paste0("-", nrow(input) - nrow(distinct(input)), " 行"), 用户决策 = "低风险自动")
# ... 每步一行；高风险项在 用户决策 列写"已确认:N:N"等
readr::write_csv(cleaning_log, "cleaning_log.csv")
```

> 高风险决策（主键不明 / N:N / 删除异常值 / 删大量缺失）在 `用户决策` 列显式记录确认结果，让"先审计后清洗"的每一步都可追溯。

## 连接前关系诊断

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

### 键一致性检查（join 前五查）

> 类型/格式不一致是**静默错匹配**的头号来源：一边 123、一边 "00123"，`as.numeric()` 一转
> 就把不同实体合并成一行，且不报任何错。统一 character 是机械步骤，**前导零是否有业务
> 语义是口径问题——必须问用户**。

```r
key_profile = \(df, key_col) tibble(
  键类型       = class(df[[key_col]])[1],
  唯一值数     = n_distinct(df[[key_col]], na.rm = TRUE),
  缺失数       = sum(is.na(df[[key_col]])),
  前导零行数   = sum(str_detect(str_trim(as.character(df[[key_col]])), "^0[0-9]"),
                     na.rm = TRUE),
  带空格行数   = sum(str_detect(as.character(df[[key_col]]), "^\\s|\\s$"),
                     na.rm = TRUE),
  大小写折叠差 = n_distinct(df[[key_col]], na.rm = TRUE) -
                 n_distinct(str_to_upper(as.character(df[[key_col]])), na.rm = TRUE),
  重复行数     = sum(duplicated(df[[key_col]]) & !is.na(df[[key_col]]))
)
key_profile(left, "customer_id")
key_profile(right, "customer_id")
```

> `大小写折叠差 > 0` = 本表内部就有 a001/A001 并存。**跨表**的大小写/空格不一致
> （两表各自内部一致、互相对不上）用下面的 `match_rate` 对比抓：

```r
match_rate = \(l, r, key) {
  lk = str_trim(str_to_upper(as.character(l[[key]])))
  rk = str_trim(str_to_upper(as.character(r[[key]])))
  c(match_raw  = mean(as.character(l[[key]]) %in% as.character(r[[key]])),
    match_norm = mean(lk %in% rk))
}
# match_norm > match_raw → 大小写/空格不一致实锤：统一后重连（口径问用户）
```

### 连接后验证（双向未匹配 + 膨胀 + 抽样核对）

```r
res = left_join(left, right, by = "customer_id")
unmatched_l = left  |> anti_join(right, by = "customer_id")
unmatched_r = right |> anti_join(left,  by = "customer_id")
# 未匹配行数 > 0：回五查 + match_rate 对比找原因（match_norm > match_raw 即
# 大小写/空格实锤），禁止静默补 NA 继续走。
# 抽样核对键映射（防"错误匹配"——验证清单拦不住错配，只能人工抽查）：
set.seed(1)
res |>
  filter(customer_id %in% sample(unique(left$customer_id), min(10, n_distinct(left$customer_id)))) |>
  select(any_of(c("customer_id", "姓名", "地区")))
```
