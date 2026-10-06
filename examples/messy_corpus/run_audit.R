#!/usr/bin/env Rscript
# run_audit.R -- run the skill's audit stage over a corpus instance.
#
# Usage (from an instance directory):
#   Rscript --vanilla ../run_audit.R input.json
#
# Follows the skill's execution protocol: paths come from the JSON, stdout is
# JSON only (no progress chatter). Snippets are taken verbatim from
# references/snippets.md so the corpus tests the DELIVERED code, not a copy.

suppressPackageStartupMessages({
  library(jsonlite)
  library(tidyverse)
})

## --- snippets.md: 缺失伪装清单与探针（审计与清洗共用） ---
na_markers    = c("", "N/A", "NA", "NULL", "NIL", "-", "--", "?", ".")
count_missing = \(x) sum(is.na(x) |
                         toupper(stringr::str_squish(as.character(x))) %in% toupper(na_markers))
safe_problems = \(x) tryCatch(nrow(readr::problems(x)), error = \(e) 0L)
parse_problems_of = \(x) {
  pp = attr(x, "parse_problems")
  if (is.null(pp)) safe_problems(x) else pp
}

## --- snippets.md: 多格式读取 ---
read_csv_anyenc = \(path) {
  b    = readBin(path, "raw", n = 1000000)
  utf8 = validUTF8(rawToChar(b))
  if (utf8 || !any(b > as.raw(0x7f))) {
    readr::read_csv(path, show_col_types = FALSE)
  } else {
    readr::read_csv(path, locale = readr::locale(encoding = "GB18030"),
                    show_col_types = FALSE)
  }
}
read_any = \(path) {
  ext = tolower(tools::file_ext(path))
  out = switch(ext,
    csv  = read_csv_anyenc(path),
    stop("unsupported format: ", path))
  pp  = safe_problems(out)
  out = as_tibble(out)
  attr(out, "parse_problems") = pp
  out
}

## --- snippets.md: 审计 ---
audit_one = \(df) list(
  shape = list(rows = nrow(df), cols = ncol(df)),
  missing = tibble(
    column   = names(df),
    na_count = map_int(df, count_missing),
    na_naive = map_int(df, \(x) sum(is.na(x)))
  ) |>
    mutate(
      na_pct    = round(na_count / nrow(df) * 100, 2),
      disguised = na_count - na_naive
    ) |>
    arrange(desc(na_count)),
  duplicate_rows = sum(duplicated(df)),
  parse_problems = parse_problems_of(df)
)

## --- snippets.md: 键一致性五查 ---
key_profile = \(df, key_col) tibble(
  键类型     = class(df[[key_col]])[1],
  唯一值数   = n_distinct(df[[key_col]], na.rm = TRUE),
  缺失数     = sum(is.na(df[[key_col]])),
  前导零行数 = sum(str_detect(str_trim(as.character(df[[key_col]])), "^0[0-9]"), na.rm = TRUE),
  带空格行数 = sum(str_detect(as.character(df[[key_col]]), "^\\s|\\s$"), na.rm = TRUE),
  重复行数   = sum(duplicated(df[[key_col]]) & !is.na(df[[key_col]]))
)

## --- snippets.md: match_rate 三口径 ---
match_rate = \(l, r, key) {
  raw      = as.character(l[[key]])
  raw_r    = as.character(r[[key]])
  norm     = str_trim(str_to_upper(raw))
  norm_r   = str_trim(str_to_upper(raw_r))
  nolead   = str_remove(norm,   "^0+(?=\\d)")
  nolead_r = str_remove(norm_r, "^0+(?=\\d)")
  c(match_raw    = mean(raw %in% raw_r),
    match_norm   = mean(norm %in% norm_r),
    match_nolead = mean(nolead %in% nolead_r))
}

args   = commandArgs(trailingOnly = TRUE)
paths  = jsonlite::fromJSON(args[1])$files
tables = map(paths, read_any)

result = if (length(tables) == 1) {
  audit_one(tables[[1]])
} else {
  left    = tables[[1]]
  right   = tables[[2]]
  common  = intersect(names(left), names(right))
  key     = common[[1]]
  left_dup  = left  |> count(.data[[key]]) |> filter(n > 1)
  right_dup = right |> count(.data[[key]]) |> filter(n > 1)
  list(
    audits      = map(tables, audit_one),
    common_keys = common,
    key         = key,
    profiles    = bind_rows(
      key_profile(left,  key) |> mutate(side = "left",  .before = 1),
      key_profile(right, key) |> mutate(side = "right", .before = 1)),
    relationship = case_when(
      nrow(left_dup) == 0 & nrow(right_dup) == 0 ~ "1:1",
      nrow(left_dup) > 0  & nrow(right_dup) == 0 ~ "N:1",
      nrow(left_dup) == 0 & nrow(right_dup) > 0  ~ "1:N",
      TRUE ~ "N:N"),
    match_rate  = as.list(match_rate(left, right, key))
  )
}

cat(jsonlite::toJSON(result, auto_unbox = TRUE, pretty = FALSE, force = TRUE))
