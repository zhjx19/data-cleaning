#!/usr/bin/env Rscript
# verify_snippets.R -- one-click regression for the data-cleaning skill.
#
# Verifies every code snippet in references/snippets.md against fixture data,
# plus a static lint of templates/*.qmd for forbidden R patterns.
#
# Usage (any CWD):
#   Rscript --vanilla scripts/verify_snippets.R
# Exit code 0 = all PASS, 1 = at least one FAIL.

suppressPackageStartupMessages({
  library(tidyverse)
})

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

# Resolve repo root from this script's path (works from any CWD).
args_full = commandArgs(trailingOnly = FALSE)
file_arg  = sub("^--file=", "", args_full[grep("^--file=", args_full)])
if (length(file_arg) == 0) stop("Run via Rscript, not interactively.")
root = normalizePath(dirname(dirname(file_arg)))

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
check("T6 three formats parsed",
      sum(!is.na(date_out$date_parsed)) == 3)
check("T6 fail flag", !date_out$date_parse_fail[[1]] && date_out$date_parse_fail[[4]])

## T7 missing imputation: median via replace_na -----------------------------
imputed = tibble(x = c(1, 2, NA, 4)) |>
  mutate(x = tidyr::replace_na(x, median(x, na.rm = TRUE)))
check("T7 median impute", imputed$x[[3]] == 2)  # median of 1,2,4 = 2

## T8 IQR outlier flag (adequate n) -----------------------------------------
set.seed(1)
numdf = tibble(x = c(rnorm(100, 50, 5), 9999))
flagged = numdf
q   = quantile(flagged$x, c(0.25, 0.75), na.rm = TRUE)
iqr = IQR(flagged$x, na.rm = TRUE)
flagged$x_outlier_flag = !is.na(flagged$x) &
  (flagged$x < (q[[1]] - 1.5 * iqr) | flagged$x > (q[[2]] + 1.5 * iqr))
check("T8 IQR catches injected outlier",
      sum(flagged$x_outlier_flag) == 1 && flagged$x_outlier_flag[[101]])

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
tmp  = tempdir()
src  = tibble(a = 1:3, b = c("x", "y", "z"))
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

## T12 static lint: templates must obey the skill's own R iron rules --------
# One check per .qmd found, so the total check count scales with templates/.
qmd_files = list.files(file.path(root, "templates"),
                       pattern = "\\.qmd$", full.names = TRUE,
                       ignore.case = TRUE)
if (length(qmd_files) == 0) {
  check("T12 qmd lint", FALSE, "no .qmd template found")
} else {
  for (qf in qmd_files) {
    txt = paste(readLines(qf, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
    txt = gsub("(?s)<!--.*?-->", "", txt, perl = TRUE)          # strip HTML comments
    lines = unlist(strsplit(txt, "\n"))
    lines = lines[!grepl("#", lines, fixed = TRUE)]              # drop comment/heading lines
    body  = paste(lines, collapse = "\n")
    # dplyr's retired scoped verbs are banned by name; a bare "_if(" would
    # false-positive on legitimate tidyr functions like na_if().
    banned = c("function(", "%>%", "ifelse(", "merge(", "gather(", "spread(", "<-",
               "mutate_if(", "mutate_at(", "mutate_all(",
               "summarise_if(", "summarise_at(", "summarise_all(",
               "summarize_if(", "summarize_at(", "summarize_all(",
               "transmute_if(", "transmute_at(", "transmute_all(",
               "select_if(", "select_at(", "select_all(",
               "rename_if(", "rename_at(", "rename_all(",
               "filter_if(", "filter_at(", "filter_all(",
               "arrange_if(", "arrange_at(", "arrange_all(",
               "group_by_if(", "group_by_at(", "group_by_all(",
               "count_if(", "distinct_if(", "distinct_at(", "distinct_all(")
    hits = banned[vapply(banned, \(p) grepl(p, body, fixed = TRUE), logical(1))]
    check(paste0("T12 lint ", basename(qf)), length(hits) == 0,
          if (length(hits)) paste("found:", paste(hits, collapse = ", ")) else "")
  }
}

## ---------------------------------------------------------------- summary
cat(sprintf("\nSummary: %d check(s), %d failure(s)\n", total, failures))
if (failures > 0) quit(status = 1)
