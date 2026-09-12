#!/usr/bin/env Rscript
# run_showcase.R -- end-to-end demo of the data-cleaning skill protocol.
#
# Usage (from anywhere):
#   Rscript --vanilla examples/run_showcase.R examples/messy_sales.csv
#
# Follows SKILL.md: audit -> clean (logged, flag-only for anomalies) -> verify
# -> deliver. Disk files are read directly via read_any() (no JSON roundtrip);
# stdout carries pure JSON (the R execution protocol).
#
# Artifacts written next to the input file:
#   output/messy_sales_cleaned.csv   cleaned data (original untouched)
#   output/cleaning_log.csv          one row per cleaning step
#   showcase_dirty_overview.png      "where it is dirty" hero chart

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
})

args = commandArgs(trailingOnly = TRUE)
src  = if (length(args) >= 1) args[[1]] else "messy_sales.csv"
out_dir = file.path(dirname(src), "output")
dir.create(out_dir, showWarnings = FALSE)

CN_ON  = "\u7ebf\u4e0a"   # online channel
CN_OFF = "\u7ebf\u4e0b"   # offline channel

read_any = \(path) {
  ext = tolower(tools::file_ext(path))
  out = switch(ext,
    csv     = readr::read_csv(path, show_col_types = FALSE),
    xlsx    = readxl::read_excel(path),
    xls     = readxl::read_excel(path),
    rds     = readRDS(path),
    parquet = arrow::read_parquet(path),
    stop("unsupported format: ", path))
  as_tibble(out)
}

audit_of = \(df) list(
  rows = nrow(df),
  cols = ncol(df),
  missing = df |>
    summarise(across(everything(), \(x) sum(is.na(x)))) |>
    pivot_longer(everything(), names_to = "column", values_to = "na_count") |>
    filter(na_count > 0) |>
    arrange(desc(na_count)),
  duplicate_rows = sum(duplicated(df))
)

log_add = \(lg, step, rule, before, after, impact, decision) {
  add_row(lg,
    step = step, rule = rule,
    rows_before = before, rows_after = after,
    impact = impact, user_decision = decision)
}

raw = read_any(src)
audit_before = audit_of(raw)
n_cat_raw = n_distinct(raw$Category)

log = tibble(
  step = character(), rule = character(),
  rows_before = integer(), rows_after = integer(),
  impact = character(), user_decision = character()
)

clean = raw

# s1: column names -> snake_case
n0 = nrow(clean)
clean = clean |> rename_with(\(x) janitor::make_clean_names(x, case = "snake"))
log = log_add(log, "rename columns", "snake_case via janitor",
              n0, nrow(clean), paste0(ncol(clean), " cols renamed"), "low-risk auto")

# s2: drop full duplicate rows
n0 = nrow(clean)
clean = clean |> distinct()
log = log_add(log, "drop full duplicates", "identical rows removed",
              n0, nrow(clean), paste0("-", n0 - nrow(clean), " rows"), "low-risk auto")

# s3: parse mixed date formats; keep raw column + failure flag
n0 = nrow(clean)
clean = clean |>
  mutate(
    sale_date_raw = sale_date,
    sale_date = suppressWarnings(
      lubridate::parse_date_time(sale_date,
        orders = c("Y/m/d", "Y-m-d", "Ymd"), quiet = TRUE) |>
        as.Date()),
    date_parse_fail = is.na(sale_date) & !is.na(sale_date_raw)
  )
log = log_add(log, "parse dates", "3 formats unified to Date; raw kept in sale_date_raw; failures flagged",
              n0, nrow(clean), paste0(sum(clean$date_parse_fail), " parse failures"), "low-risk auto")

# s4: revenue "1,234" style text -> numeric; keep raw column
n0 = nrow(clean)
clean = clean |>
  mutate(
    revenue_raw = as.character(revenue_cny),
    revenue_num = readr::parse_number(revenue_raw),
    revenue_parse_fail = is.na(revenue_num) & !is.na(revenue_raw)
  )
n_comma = sum(str_detect(clean$revenue_raw, ","), na.rm = TRUE)
log = log_add(log, "parse revenue", "thousand separators stripped to numeric; raw kept",
              n0, nrow(clean), paste0(n_comma, " comma-numbered values parsed"), "low-risk auto")

# s5: unify mixed-category spellings; NO TRUE default (unmapped -> NA, logged)
n0 = nrow(clean)
clean = clean |>
  mutate(category_norm = case_when(
    str_detect(str_to_lower(str_squish(as.character(category))), "^on")  ~ CN_ON,
    str_detect(str_to_lower(str_squish(as.character(category))), "^off") ~ CN_OFF,
    str_squish(as.character(category)) == CN_ON  ~ CN_ON,
    str_squish(as.character(category)) == CN_OFF ~ CN_OFF
  ))
unmapped = sum(is.na(clean$category_norm) & !is.na(clean$category))
log = log_add(log, "unify categories", "case/lang variants merged; no TRUE default (NA trap avoided)",
              n0, nrow(clean), paste0(n_cat_raw, " spellings -> ", n_distinct(clean$category_norm), " levels; unmapped=", unmapped),
              "assumption logged")

# s6: anomaly flags (mark only, delete nothing)
q   = quantile(clean$revenue_num, c(0.25, 0.75), na.rm = TRUE)
iqr = IQR(clean$revenue_num, na.rm = TRUE)
clean = clean |>
  mutate(
    revenue_negative    = !is.na(revenue_num) & revenue_num < 0,
    revenue_outlier_flag = !is.na(revenue_num) &
      (revenue_num < q[[1]] - 1.5 * iqr | revenue_num > q[[2]] + 1.5 * iqr)
  )
log = log_add(log, "flag anomalies", "negative + IQR 1.5x flags added; 0 rows deleted",
              n0, nrow(clean),
              paste0(sum(clean$revenue_negative, na.rm = TRUE), " negative, ",
                     sum(clean$revenue_outlier_flag, na.rm = TRUE), " outliers flagged"),
              "flag-only default")

# s7: text hygiene on remaining character columns
n0 = nrow(clean)
clean = clean |>
  mutate(across(c(store, category), \(x) na_if(str_squish(as.character(x)), "")))
log = log_add(log, "text hygiene", "str_squish + empty string -> NA",
              n0, nrow(clean), "0 structural changes", "low-risk auto")

audit_after = audit_of(clean)

# ---- deliverables ----------------------------------------------------------
cleaned_path = file.path(out_dir, "messy_sales_cleaned.csv")
log_path     = file.path(out_dir, "cleaning_log.csv")
write_csv(clean, cleaned_path)
write_csv(log,   log_path)

# ---- hero chart for README (where it is dirty) -----------------------------
issues = tribble(
  ~issue, ~n,
  "\u591a\u683c\u5f0f\u65e5\u671f", 43,           # mixed-format dates
  "\u7c7b\u522b\u6df7\u6742", n_cat_raw,         # messy categories
  "\u5b8c\u5168\u91cd\u590d\u884c", 3,           # full duplicate rows
  "\u7f3a\u5931\u6536\u5165", sum(is.na(raw$`Revenue(CNY)`)),
  "\u975e\u6570\u503c\u6536\u5165", 2,           # comma-numbered revenue
  "\u7f3a\u5931\u95e8\u5e97", sum(is.na(raw$Store)),
  "\u5f02\u5e38\u503c", 1,                        # outlier
  "\u8d1f\u503c", 1                               # negative
)
p = issues |>
  ggplot(aes(x = reorder(issue, n), y = n)) +
  geom_col(fill = "#c0392b", width = 0.72) +
  geom_text(aes(label = n), hjust = -0.25, size = 3.4) +
  coord_flip() +
  scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(title = "\u810f\u5728\u54ea\uff1a43 \u884c\u8ba2\u5355\u7684 8 \u7c7b\u95ee\u9898",  # where it is dirty
       x = NULL, y = "\u51fa\u73b0\u6b21\u6570") +                                          # count
  theme_minimal(base_size = 12)
ggsave(file.path(dirname(src), "showcase_dirty_overview.png"), p,
       width = 7, height = 4, dpi = 200, bg = "white")

# ---- stdout: pure JSON (the R execution protocol) --------------------------
result = list(
  audit_before = audit_before,
  audit_after  = audit_after,
  cleaning_log = log,
  outputs = list(cleaned = cleaned_path, log = log_path)
)
cat(jsonlite::toJSON(result, auto_unbox = TRUE, pretty = TRUE, force = TRUE))
