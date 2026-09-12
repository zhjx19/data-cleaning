# Vendored: PrettyTypst

- **来源**: https://github.com/nrennie/PrettyTypst （Nicola Rennie）
- **许可**: CC0 1.0（本目录整体沿用 CC0；上游 LICENSE 见其仓库）
- **vendor 原因**: data-cleaning skill 的质量报告承诺「离线可渲染」，不要求用户联网 `quarto add`。
- **本地改动**（相对 upstream v0.0.2）:
  1. `typst-template.typ` 两处 `font: "Ubuntu"` 改为显式 CJK 回退链
     `("Ubuntu", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC")`，
     保证中文在 Windows/macOS/Linux 上确定性渲染。
  2. 其余文件与 upstream 保持一致；升级 upstream 时需重打补丁 1。
