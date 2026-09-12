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
na_tbl = input |>
  summarise(across(everything(), \(x) mean(is.na(x)))) |>
  pivot_longer(everything(), names_to = "column", values_to = "na_rate") |>
  mutate(band = case_when(
    na_rate <  0.05 ~ "impute-ok",   # 非关键列可默认填补
    na_rate <= 0.40 ~ "ask",         # 报告并询问
    TRUE            ~ "flag-drop"    # 标记待删/待补，用户拍板
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

## 多格式读取（CSV / Excel / RDS / Parquet）

多文件场景直接在 `.R` 脚本内按扩展名读入多张表，不依赖单 `input`（需 `readxl` / `arrow`）：

```r
read_any = \(path) {
  ext = tolower(tools::file_ext(path))
  out = switch(ext,
    csv     = readr::read_csv(path, show_col_types = FALSE),
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
  键类型     = class(df[[key_col]])[1],
  唯一值数   = n_distinct(df[[key_col]]),
  缺失数     = sum(is.na(df[[key_col]])),
  前导零行数 = sum(str_detect(str_trim(as.character(df[[key_col]])), "^0[0-9]")),
  重复行数   = sum(duplicated(df[[key_col]]) & !is.na(df[[key_col]]))
)
key_profile(left, "customer_id")
key_profile(right, "customer_id")
```

### 连接后验证（双向未匹配 + 膨胀 + 抽样核对）

```r
res = left_join(left, right, by = "customer_id")
unmatched_l = left  |> anti_join(right, by = "customer_id")
unmatched_r = right |> anti_join(left,  by = "customer_id")
# 未匹配行数 > 0：先回键一致性五查找原因，禁止静默补 NA 继续走。
# 抽样核对键映射（防"错误匹配"——验证清单拦不住错配，只能人工抽查）：
set.seed(1)
res |>
  filter(customer_id %in% sample(unique(left$customer_id), min(10, n_distinct(left$customer_id)))) |>
  select(any_of(c("customer_id", "姓名", "地区")))
```
