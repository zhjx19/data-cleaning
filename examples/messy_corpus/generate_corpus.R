#!/usr/bin/env Rscript
# generate_corpus.R -- rebuild examples/messy_corpus/ from scratch.
#
# The corpus is GENERATED, not hand-written: {messy} injects the dirt with
# pinned seeds, and each expected.json is DERIVED FROM THE FILE AS READ BACK
# (i.e. what an agent actually sees) -- the answer key can never drift from
# the fixtures, and it cannot silently disagree with the on-disk bytes.
#
# Usage (any CWD):
#   Rscript --vanilla examples/messy_corpus/generate_corpus.R
#
# Requires: tidyverse, messy, scales, jsonlite.

suppressPackageStartupMessages({
  library(tidyverse)
  library(messy)
  library(scales)
})

args_all = commandArgs(trailingOnly = FALSE)
script   = sub("^--file=", "", args_all[grep("^--file=", args_all)])
root     = dirname(normalizePath(script))

## Missing-marker vocabulary: SAME definition as references/snippets.md
## ("missing-disguise unification"). Two copies would drift -- keep in sync.
na_markers = c("", "N/A", "NA", "NULL", "NIL", "-", "--", "?", ".")
is_missing_any = \(x) {
  is.na(x) | toupper(stringr::str_squish(as.character(x))) %in% toupper(na_markers)
}
band_of = \(rate) dplyr::case_when(
  rate <  0.05 ~ "impute-ok",
  rate <= 0.40 ~ "ask",
  TRUE         ~ "flag-drop")

write_expected = \(dir, obj) writeLines(
  jsonlite::toJSON(obj, auto_unbox = TRUE, pretty = TRUE, null = "null"),
  file.path(dir, "expected.json"))

## =====================================================================
## inst1_missing_bands -- the missing-value three-band decision line.
##
##   region  ~5%  disguised as the literal "N/A" (and "n/a" after case
##                messing) -> is.na() reports 0%  => the band FLIPS
##                (truth "ask" vs naive "impute-ok")
##   channel ~3%  plain NA   -> "impute-ok"  (the <5% branch)
##   score   ~34% plain NA   -> "ask"
##   note    ~49% empty ""   -> "flag-drop"  (note: CSV read-back turns ""
##                              into NA, so this one is NOT a trap)
##
## Note for fixture authors: readr reads BOTH unquoted and quoted empty
## fields as NA, so an "" disguise never survives a CSV round trip. It is
## still a real trap for in-memory / Excel / JSON sources.
## =====================================================================
set.seed(2026)
n = 100
truth1 = tibble(
  id      = sprintf("R-%03d", 1:n),
  region  = rep(c("East", "West", "North", "South"), length.out = n),
  channel = rep(c("Search", "Social", "Email"), length.out = n),
  score   = rep(c(10, 20, 30, 40, 50, 60, 70, 80), length.out = n),
  note    = paste0("note-", 1:n),
  amount  = rep(c(120.5, 45, 300.25, 88), length.out = n))

dirty1 = truth1 |>
  make_missing(cols = "region",  messiness = 0.02, missing = "N/A") |>
  make_missing(cols = "channel", messiness = 0.01, missing = NA) |>
  make_missing(cols = "score",   messiness = 0.25, missing = NA) |>
  make_missing(cols = "note",    messiness = 0.55, missing = "") |>
  add_whitespace(cols = c("region", "channel"), messiness = 0.3) |>
  change_case(cols = c("region", "channel"), messiness = 0.4)

d1 = file.path(root, "inst1_missing_bands")
dir.create(d1, showWarnings = FALSE, recursive = TRUE)
write_csv(dirty1, file.path(d1, "dirty.csv"))
write_csv(truth1, file.path(d1, "truth.csv"))
writeLines('{"files": ["dirty.csv"]}', file.path(d1, "input.json"))

## expectations are computed on the READ-BACK file, never on the in-memory tibble
seen1 = readr::read_csv(file.path(d1, "dirty.csv"), show_col_types = FALSE)
as_named = \(x, cols) set_names(as.list(x), cols)
rate_true  = map_dbl(seen1, \(x) mean(is_missing_any(x)))
rate_naive = map_dbl(seen1, \(x) mean(is.na(x)))
band_true  = band_of(rate_true)
band_naive = band_of(rate_naive)
write_expected(d1, list(
  focus = "missing_bands",
  rows  = nrow(seen1),
  missing_pct_true  = as_named(round(rate_true  * 100, 1), names(seen1)),
  missing_pct_naive = as_named(round(rate_naive * 100, 1), names(seen1)),
  band_true  = as_named(band_true,  names(seen1)),
  band_naive = as_named(band_naive, names(seen1)),
  band_flip  = names(seen1)[band_true != band_naive],
  must_pause = map_chr(names(seen1)[band_true %in% c("ask", "flag-drop")], \(col) {
    r = round(rate_true[[col]] * 100, 1)
    if (band_true[[col]] == "flag-drop") {
      sprintf("%s: %s%% (>40%%) -- do not impute, do not drop; list for user decision", col, r)
    } else {
      sprintf("%s: %s%% (5-40%%) -- keep NA, report and ask", col, r)
    }
  }),
  trap = map_chr(names(seen1)[band_true != band_naive], \(col) {
    sprintf(paste("%s: missingness is written as the literal N/A / n/a;",
                  "is.na() alone reports %s%% instead of %s%%, flipping the band %s -> %s"),
            col, round(rate_naive[[col]] * 100, 1), round(rate_true[[col]] * 100, 1),
            band_naive[[col]], band_true[[col]])
  })
))

## =====================================================================
## inst2_join_nn -- multi-file, N:N relationship + leading-zero key drift.
## Both sides have duplicate keys -> N:N (must stop). orders' customer_id
## is zero-padded character ("001"), customers' is plain numeric (1).
## =====================================================================
set.seed(2027)
orders = tibble(
  order_id    = sprintf("SO-%04d", 1:12),
  customer_id = c("001", "002", "002", "003", "004", "004", "004",
                  "005", "006", "007", "008", "008"),
  amount      = c(100, 200, 150, 300, 250, 400, 120, 90, 500, 60, 700, 80))
customers = tibble(
  customer_id = c(1, 2, 2, 3, 4, 5, 6, 6, 7, 8),
  name        = c("Acme", "Borealis", "Borealis Ltd", "Cobalt", "Delta",
                  "Everest", "Fjord", "Fjord Inc", "Gale", "Harbor"),
  city        = c("Beijing", "Shanghai", "Shanghai", "Shenzhen", "Chengdu",
                  "Wuhan", "Hangzhou", "Hangzhou", "Xian", "Nanjing"))

d2 = file.path(root, "inst2_join_nn")
dir.create(d2, showWarnings = FALSE, recursive = TRUE)
write_csv(orders,    file.path(d2, "orders.csv"))
write_csv(customers, file.path(d2, "customers.csv"))
writeLines('{"files": ["orders.csv", "customers.csv"]}', file.path(d2, "input.json"))

match_rate = \(l, r, k) {
  lk = str_trim(str_to_upper(as.character(l[[k]])))
  rk = str_trim(str_to_upper(as.character(r[[k]])))
  c(match_raw = mean(as.character(l[[k]]) %in% as.character(r[[k]])),
    match_norm = mean(lk %in% rk))
}
mr = match_rate(orders, customers, "customer_id")
write_expected(d2, list(
  focus        = "join_nn_leading_zero",
  key          = "customer_id",
  relationship = "N:N",
  leading_zero_rows = list(
    orders    = sum(str_detect(orders$customer_id, "^0[0-9]")),
    customers = sum(str_detect(as.character(customers$customer_id), "^0[0-9]"))),
  match_raw    = unname(mr[["match_raw"]]),
  match_norm   = unname(mr[["match_norm"]]),
  must_pause   = c(
    "relationship is N:N -- stop; aggregate/dedupe/add a key before joining",
    "leading zeros on orders' key: is 001 the same entity as 1? ask the user")
))

## =====================================================================
## inst3_gbk_cn -- GBK-encoded Chinese CSV (silent-mojibake defence).
## Written as GB18030 on purpose; readr's default read does NOT error, it
## silently keeps the raw bytes.
## =====================================================================
set.seed(2028)
truth3 = tibble(
  订单号 = sprintf("CN-%03d", 1:40),
  地区   = rep(c("华东", "华北", "华南", "西南"), length.out = 40),
  品类   = rep(c("电子", "家具", "办公"), length.out = 40),
  金额   = rep(c("¥1,200.50", "¥345", "¥2,058.00", "¥88"), length.out = 40),
  状态   = rep(c("已发货", "待处理"), length.out = 40))
dirty3 = truth3 |>
  add_whitespace(cols = c("地区", "品类", "状态"), messiness = 0.25) |>
  make_missing(cols = "状态", messiness = 0.15, missing = "N/A")

d3 = file.path(root, "inst3_gbk_cn")
dir.create(d3, showWarnings = FALSE, recursive = TRUE)
write.csv(dirty3, file.path(d3, "dirty.csv"), row.names = FALSE, fileEncoding = "GB18030")
write_csv(truth3, file.path(d3, "truth.csv"))
writeLines('{"files": ["dirty.csv"]}', file.path(d3, "input.json"))

seen3 = readr::read_csv(file.path(d3, "dirty.csv"),
                        locale = readr::locale(encoding = "GB18030"),
                        show_col_types = FALSE)
write_expected(d3, list(
  focus       = "gbk_chinese_csv",
  encoding    = "GB18030",
  rows        = nrow(seen3),
  cols        = ncol(seen3),
  parse_issue_count = nrow(problems(seen3)),
  must_pause  = "none -- but parse issues must be REPORTED, not swallowed by stderr"
))

cat("corpus regenerated at:", root, "\n")
for (d in c(d1, d2, d3)) {
  e = jsonlite::fromJSON(file.path(d, "expected.json"))
  cat(sprintf("  %-22s focus=%-22s rows=%s\n", basename(d), e$focus, e$rows))
}
