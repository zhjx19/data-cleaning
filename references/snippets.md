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

## 缺失值填补（示例，不可盲用）

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

## 异常值 flag（IQR，推荐默认）

> 这里用 for 循环是**列方向批量生成 flag** 的合理例外（每个数值列生成一个新列，`across()` 不便逐列命名）；清洗主流程仍遵守"禁 for 循环逐行"铁律。

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
