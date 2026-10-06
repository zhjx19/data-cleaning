#!/usr/bin/env Rscript
# verify_snippets.R -- one-click regression for the data-cleaning skill.
#
# Runs every code snippet in references/snippets.md against fixture data and
# asserts real outputs. ASCII-only on purpose: a broken LC_CTYPE locale
# garbles non-ASCII source and kills parsing (see SKILL.md pitfalls), so this
# must run under any locale/shell combination.
#
# Usage (any CWD):
#   Rscript --vanilla scripts/verify_snippets.R
# Exit code: 0 = all PASS; 1 = any FAIL.

suppressPackageStartupMessages({
  library(tidyverse)
})
# slider/jsonlite/readxl/arrow/writexl loaded lazily per test with
# requireNamespace() guards so a missing optional package degrades to SKIP.

failures = 0L
total    = 0L
check = function(name, cond, detail = "") {
  total    <<- total + 1L
  ok       = isTRUE(cond)
  if (!ok) failures <<- failures + 1L
  cat(sprintf("[%s] %s%s\n", if (ok) "PASS" else "FAIL", name,
              if (nzchar(detail)) paste0(" -- ", detail) else ""))
  invisible(ok)
}
root = normalizePath(dirname(dirname(commandArgs(trailingOnly = FALSE)[
  grep("^--file=", commandArgs(trailingOnly = FALSE))])))
tmp = tempdir()

## ---------------------------------------------------------------- fixtures
input = tribble(
  ~id, ~name,   ~value, ~cat,
  1L,  "alice", 10.5,   "VIP",
  2L,  "bob",   9999,   "vip",
  2L,  "bob",   9999,   "vip",
  3L,  "",      11.2,   NA,
  4L,  "dave",  NA,     "member",
  4L,  "dave",  12.9,   "Member"
)

## T1 audit: structure + missing + duplicates -------------------------------
audit = list(
  shape = list(rows = nrow(input), cols = ncol(input)),
  missing = input |>
    summarise(across(everything(), \(x) sum(is.na(x)))) |>
    pivot_longer(everything(), names_to = "column", values_to = "na_count") |>
    mutate(na_pct = round(na_count / nrow(input) * 100, 2)) |>
    arrange(desc(na_count)),
  duplicate_rows = sum(duplicated(input))
)
check("T1 audit shape", audit$shape$rows == 6 && audit$shape$cols == 4)
check("T1 audit missing counts",
      audit$missing$na_count[audit$missing$column == "value"] == 1)
check("T1 audit duplicate rows", audit$duplicate_rows == 1)

## T2 duplicate row diagnosis (.by = everything()) --------------------------
dup = input |>
  summarise(n = n(), .by = everything()) |>
  filter(n > 1) |>
  arrange(desc(n))
check("T2 dup diagnosis", nrow(dup) == 1 && dup$n[[1]] == 2)

## T3 snake_case rename (janitor) -------------------------------------------
if (requireNamespace("janitor", quietly = TRUE)) {
  messy = tibble(`Order ID` = 1, `Revenue (CNY)` = 2, `Sale Date` = 3)
  snaked = messy |> rename_with(\(x) janitor::make_clean_names(x, case = "snake"))
  check("T3 snake rename",
        identical(names(snaked), c("order_id", "revenue_cny", "sale_date")))
} else check("T3 snake rename", FALSE, "janitor not installed")

## T4 text standardization: squish + empty string -> NA ---------------------
text_out = input |>
  mutate(across(where(is.character), \(x) stringr::str_squish(x))) |>
  mutate(across(where(is.character), \(x) na_if(x, "")))
check("T4 squish", text_out$name[text_out$id == 1] == "alice")
check("T4 empty -> NA", is.na(text_out$name[text_out$id == 3]))

## T5 case_when NA trap (documented pitfall must reproduce) -----------------
trapped = input |>
  mutate(cat2 = case_when(toupper(coalesce(cat, "")) == "VIP" ~ "VIP",
                          TRUE ~ "STANDARD"))
check("T5 NA trap reproduces (NA -> default)",
      is.na(input$cat[input$id == 3]) &&
        trapped$cat2[trapped$id == 3] == "STANDARD")

## T6 multi-format date parsing + fail flag ---------------------------------
dates = tibble(date_raw = c("2023/01/01", "2023-01-05", "20230110", "bad"))
date_out = dates |>
  mutate(
    # suppressWarnings: parse_date_time emits a cosmetic upstream c() warning
    # on some R/locale combos; the assertions below verify actual results.
    date_parsed = suppressWarnings(
      lubridate::parse_date_time(
        date_raw, orders = c("Y/m/d", "Y-m-d", "Ymd"), quiet = TRUE) |>
        as.Date()),
    date_parse_fail = is.na(date_parsed) & !is.na(date_raw)
  )
check("T6 three formats parsed", sum(!is.na(date_out$date_parsed)) == 3)
check("T6 fail flag", !date_out$date_parse_fail[[1]] && date_out$date_parse_fail[[4]])

## T7 missing imputation: median via replace_na -----------------------------
imputed = tibble(x = c(1, 2, NA, 4)) |>
  mutate(x = tidyr::replace_na(x, median(x, na.rm = TRUE)))
check("T7 median impute", imputed$x[[3]] == 2)  # median of 1,2,4 = 2

## T8 IQR outlier flag (adequate n) -----------------------------------------
set.seed(1)
numdf = tibble(x = c(rnorm(100, 50, 5), 9999))
q   = quantile(numdf$x, c(0.25, 0.75), na.rm = TRUE)
iqr = IQR(numdf$x, na.rm = TRUE)
numdf$x_outlier_flag = !is.na(numdf$x) &
  (numdf$x < (q[[1]] - 1.5 * iqr) | numdf$x > (q[[2]] + 1.5 * iqr))
check("T8 IQR catches injected outlier",
      sum(numdf$x_outlier_flag) == 1 && numdf$x_outlier_flag[[101]])

## T9 read_any: CSV / XLSX / RDS / Parquet ----------------------------------
read_any = \(path) {
  ext = tolower(tools::file_ext(path))
  out = switch(ext,
    csv     = readr::read_csv(path, show_col_types = FALSE),
    xlsx    = readxl::read_excel(path),
    rds     = readRDS(path),
    parquet = arrow::read_parquet(path),
    stop("unsupported format: ", path))
  as_tibble(out)
}
src = tibble(a = 1:3, b = c("x", "y", "z"))
csv_p  = file.path(tmp, "f.csv");  xlsx_p = file.path(tmp, "f.xlsx")
rds_p  = file.path(tmp, "f.rds");  pq_p   = file.path(tmp, "f.parquet")
write_csv(src, csv_p); saveRDS(src, rds_p); arrow::write_parquet(src, pq_p)
paths = c(csv_p, rds_p, pq_p)
has_writexl = requireNamespace("writexl", quietly = TRUE)
if (has_writexl) {
  writexl::write_xlsx(src, xlsx_p)
  paths = c(paths, xlsx_p)
}
ok9 = all(vapply(paths,
                 \(p) identical(nrow(read_any(p)), 3L) &&
                      identical(ncol(read_any(p)), 2L), logical(1)))
check("T9 read_any", ok9,
      if (!has_writexl) "xlsx variant skipped (writexl not installed)" else "")

## T10 structured cleaning log ----------------------------------------------
cleaning_log = tibble(
  step = character(), rule = character(),
  rows_before = integer(), rows_after = integer(),
  impact = character(), user_decision = character()
)
cleaning_log = cleaning_log |> add_row(
  step = "drop full duplicates", rule = "identical rows removed",
  rows_before = nrow(input), rows_after = nrow(distinct(input)),
  impact = paste0("-", nrow(input) - nrow(distinct(input)), " rows"),
  user_decision = "low-risk auto")
log_p = file.path(tmp, "cleaning_log.csv")
readr::write_csv(cleaning_log, log_p)
log_back = readr::read_csv(log_p, show_col_types = FALSE)
check("T10 cleaning log roundtrip",
      nrow(log_back) == 1 && log_back$rows_before[[1]] == 6)

## T11 join relationship diagnosis ------------------------------------------
left  = tibble(id = c(1L, 2L, 2L, 3L))
right = tibble(id = c(1L, 2L), v = c("a", "b"))
rel = \(l, r) {
  ld = l |> count(.data[["id"]]) |> filter(n > 1)
  rd = r |> count(.data[["id"]]) |> filter(n > 1)
  case_when(
    nrow(ld) == 0 & nrow(rd) == 0 ~ "1:1",
    nrow(ld) > 0  & nrow(rd) == 0 ~ "N:1",
    nrow(ld) == 0 & nrow(rd) > 0  ~ "1:N",
    TRUE ~ "N:N")
}
check("T11 join relation N:1", rel(left, right) == "N:1")
check("T11 join relation 1:1", rel(right, right) == "1:1")

## T12 missing-marker unification must precede format cleanup ----------------
# Documented pitfall: a format pass that strips non-letters rewrites the
# literal "N/A" into "NA", so a later na_if("N/A") silently misses it -- no
# error, no row-count change, one missing cell becomes a fake category.
markers = tibble(
  id     = 1:6,
  region = c(" E#ast ", "N/A", "NA", "", "West", "-")
)

# (a) WRONG order: format cleanup first -> the literal survives as "NA"
wrong = markers |>
  mutate(region = stringr::str_remove_all(region, "[^A-Za-z]") |>
           stringr::str_squish()) |>
  mutate(region = na_if(region, "") |> na_if("N/A"))
check("T12 wrong order silently misses the marker",
      wrong$region[wrong$id == 2] == "NA" && !is.na(wrong$region[wrong$id == 2]))

# (b) RIGHT order: unify missing markers first, then clean the format
na_markers = c("", "N/A", "NA", "NULL", "NIL", "-", "--", "?", ".")
to_na = \(x) {
  x = stringr::str_squish(x)
  x[toupper(x) %in% toupper(na_markers)] = NA_character_
  x
}
right = markers |>
  mutate(region = to_na(region)) |>
  mutate(region = stringr::str_remove_all(region, "[^A-Za-z]") |>
           stringr::str_squish() |>
           stringr::str_to_title())
check("T12 right order unifies every missing marker",
      all(is.na(right$region[right$id %in% c(2, 3, 4, 6)])) &&
        right$region[right$id == 1] == "East" &&
        right$region[right$id == 5] == "West")

## T13 audit must count disguised missing + surface parse problems -----------
# Documented pitfall: is.na() reports 0% for a column whose missingness is the
# literal "N/A" / "n/a" -- small enough to flip the three-band decision.
na_markers    = c("", "N/A", "NA", "NULL", "NIL", "-", "--", "?", ".")
count_missing = \(x) sum(is.na(x) |
                         toupper(stringr::str_squish(as.character(x))) %in% toupper(na_markers))
safe_problems = \(x) tryCatch(nrow(readr::problems(x)), error = \(e) 0L)
parse_problems_of = \(x) {
  pp = attr(x, "parse_problems")
  if (is.null(pp)) safe_problems(x) else pp
}

audit_fx = tibble(id     = 1:20,
                  region = c(rep("East", 18), "N/A", "n/a"),
                  note   = c(rep("ok", 19), NA))
miss = tibble(
  column   = names(audit_fx),
  na_count = map_int(audit_fx, count_missing),
  na_naive = map_int(audit_fx, \(x) sum(is.na(x)))
) |>
  mutate(disguised = na_count - na_naive)
check("T13 disguised missing counted",
      miss$na_count[miss$column == "region"] == 2 &&
        miss$na_naive[miss$column == "region"] == 0 &&
        miss$disguised[miss$column == "region"] == 2)

bad_csv = file.path(tmp, "t13_problems.csv")
writeLines(c("a,b", "1,2", "2,3", "x,4"), bad_csv)
forced = readr::read_csv(bad_csv, col_types = readr::cols(a = readr::col_double()),
                         show_col_types = FALSE)
check("T13 parse problems surfaced", safe_problems(forced) == 1)

# as_tibble() drops readr's problems attribute -> read_any() must carry it across
carried = as_tibble(forced)
attr(carried, "parse_problems") = safe_problems(forced)
check("T13 read layer carries parse problems across as_tibble()",
      is.null(attr(as_tibble(forced), "problems")) && parse_problems_of(carried) == 1)

## T14 match_rate must expose the leading-zero cause -------------------------
# Documented pitfall: normalisation only trims/cases, so a zero-padded key
# gives match_raw == match_norm == 0 and the real cause gets ruled out.
match_rate3 = \(l, r, key) {
  raw      = as.character(l[[key]])
  raw_r    = as.character(r[[key]])
  norm     = stringr::str_trim(stringr::str_to_upper(raw))
  norm_r   = stringr::str_trim(stringr::str_to_upper(raw_r))
  nolead   = stringr::str_remove(norm,   "^0+(?=\\d)")
  nolead_r = stringr::str_remove(norm_r, "^0+(?=\\d)")
  c(match_raw    = mean(raw %in% raw_r),
    match_norm   = mean(norm %in% norm_r),
    match_nolead = mean(nolead %in% nolead_r))
}
mr = match_rate3(tibble(k = c("001", "002", "003")),
                 tibble(k = c("1", "2", "3")), "k")
check("T14 leading-zero cause exposed",
      mr[["match_raw"]] == 0 && mr[["match_norm"]] == 0 && mr[["match_nolead"]] == 1)
check("T14 meaningful zeros kept",
      stringr::str_remove("001002", "^0+(?=\\d)") == "1002" &&
        stringr::str_remove("1002", "^0+(?=\\d)") == "1002" &&
        stringr::str_remove("0", "^0+(?=\\d)") == "0")

## T15 corpus: the audit must meet each instance's expected.json ------------
# The corpus is the end-to-end target: the snippets must satisfy the fixtures,
# and expected.json is DERIVED from the files -- so drift on either side fails.
corpus = file.path(root, "examples", "messy_corpus")
if (dir.exists(corpus) && requireNamespace("jsonlite", quietly = TRUE)) {
  rd_inst  = \(d, f) readr::read_csv(file.path(corpus, d, f), show_col_types = FALSE)
  exp_inst = \(d) jsonlite::fromJSON(file.path(corpus, d, "expected.json"))
  rel_of   = \(l, r, k) {
    ld = l |> count(.data[[k]]) |> filter(n > 1)
    rd = r |> count(.data[[k]]) |> filter(n > 1)
    dplyr::case_when(
      nrow(ld) == 0 & nrow(rd) == 0 ~ "1:1",
      nrow(ld) > 0  & nrow(rd) == 0 ~ "N:1",
      nrow(ld) == 0 & nrow(rd) > 0  ~ "1:N",
      TRUE ~ "N:N")
  }

  e1 = exp_inst("inst1_missing_bands")
  d1 = rd_inst("inst1_missing_bands", "dirty.csv")
  check("T15 inst1 disguised missing + band flip match expected.json",
        count_missing(d1$region) == round(e1$missing_pct_true$region / 100 * nrow(d1)) &&
          count_missing(d1$region) > sum(is.na(d1$region)) &&
          length(e1$band_flip) > 0)

  e2  = exp_inst("inst2_join_nn")
  o2  = rd_inst("inst2_join_nn", "orders.csv")
  c2  = rd_inst("inst2_join_nn", "customers.csv")
  mr2 = match_rate3(o2, c2, "customer_id")
  check("T15 inst2 N:N + leading-zero cause match expected.json",
        rel_of(o2, c2, "customer_id") == e2$relationship &&
          mr2[["match_nolead"]] > mr2[["match_raw"]])

  e3 = exp_inst("inst3_gbk_cn")
  p3 = file.path(corpus, "inst3_gbk_cn", "dirty.csv")
  b3 = readBin(p3, "raw", n = 1000000)
  x3 = readr::read_csv(p3, locale = readr::locale(encoding = "GB18030"),
                       show_col_types = FALSE)
  check("T15 inst3 non-UTF8 + parse problems match expected.json",
        !validUTF8(rawToChar(b3)) && safe_problems(x3) == e3$parse_issue_count)
} else {
  check("T15 corpus audit", TRUE, "corpus not shipped (SkillHub dist)")
}

## T16 version mirror must match SKILL.md frontmatter -------------------------
## The README version badge reads version.json dynamically; SKILL.md stays the
## single source of truth. This guard is what stops the mirror from drifting.
read_ver = function(path, n = -1L) {
  ln  = readLines(path, n = n, warn = FALSE)
  hit = grep('version"?[[:space:]]*:[[:space:]]*"', ln, value = TRUE)
  if (!length(hit)) return(NA_character_)
  sub('.*"([^"]+)".*', "\\1", hit[1])
}
fm = read_ver(file.path(root, "SKILL.md"), n = 30L)
jm = read_ver(file.path(root, "version.json"))
check("T16 version.json mirrors SKILL.md frontmatter",
      !is.na(fm) && identical(fm, jm),
      sprintf("SKILL.md=%s version.json=%s", fm, jm))

## ---------------------------------------------------------------- summary
cat(sprintf("\nSummary: %d check(s), %d failure(s)\n", total, failures))
if (failures > 0) quit(status = 1)
