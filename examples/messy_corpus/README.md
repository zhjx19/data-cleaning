# messy_corpus — 脏数据语料（每个实例都带真值答案）

三个**生成式**实例：`generate_corpus.R` 用 [{messy}](https://cran.r-project.org/package=messy)
按固定种子注入脏数据，每个 `expected.json` 由**读回后的文件**推导——答案不可能与语料脱节。

## 为什么有它

`scripts/verify_snippets.R` 只验**代码片段**；agent 工作流（审计 → 问题清单 → 暂停确认 →
清洗 → 验证 → 交付）要**整条链**跑在真数据上才看得出洞。这个语料就是那条链的靶子：每个实例
都埋了"应该被发现"的问题，和一个"应该停下来问"的点。

首轮用它跑出的三个缺陷（已修，见 CHANGELOG 1.0.1）：审计只数 `is.na()` 漏报伪装缺失、
解析问题只走 stderr、`match_rate` 抓不到前导零。

## 实例

| 实例 | 考什么 | 埋的坑 | 必须暂停确认 |
|---|---|---|---|
| `inst1_missing_bands` | 缺失三档线 | `region` 的缺失写成字面量 `N/A`/`n/a`：只数 `is.na()` 报 0%，真值 5%，**档位从「保留并询问」翻成「可填补」** | `note` 51%（>40%）、`score` 26%（5–40%） |
| `inst2_join_nn` | 多文件连接诊断 | 两侧键都有重复 → **N:N**；`orders` 键带前导零（`001`）对 `customers` 的 `1`，`match_raw == match_norm == 0`，只有第三口径 `match_nolead` 能实锤 | N:N 必须先停；前导零是否同一实体 |
| `inst3_gbk_cn` | GBK 中文 CSV | 文件是 GB18030，`readr` 默认读不报错、静默留原始字节；另有 **40 条解析问题**只发 stderr warning | 无（但解析问题必须被报出来）|

## 怎么用

```bash
cd inst1_missing_bands
Rscript --vanilla ../run_audit.R input.json    # stdout 只有 JSON
```

把输出与同目录 `expected.json` 对照：`missing_pct_true` / `band_true` / `band_flip` /
`relationship` / `parse_issue_count` 都该对上。

## 重新生成

```bash
Rscript --vanilla generate_corpus.R
```

固定种子 + 固定 `messy` 版本 → 同样的 CSV。**改语料请改 `generate_corpus.R`，不要手改 CSV**
（手改会让 `expected.json` 与数据脱节，这个语料的价值就在于两者永远一致）。

## 给语料作者的两条经验

1. **期望值一律从"读回的文件"算**，不要在内存对象上算。首版就栽在这里：内存里 `note` 的缺失是
   空串、`is.na()` 报 0，看起来是个陷阱；落盘读回后空字段变成 `NA`，陷阱根本不存在。
2. **`readr` 把带引号的空字段 `""` 也读成 `NA`**，所以 `""` 这种伪装过不了 CSV 往返
   （它在内存 / Excel / JSON 来源里仍是真陷阱）。
