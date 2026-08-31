#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_html.py — 将 Markdown 报告转换为自包含的单文件 HTML

用法:
    python make_html.py [输出目录 ...]

不带参数时输出到脚本所在目录。可指定多个目录以同步分发。
"""
import os
import re
import sys
import html as htmlmod
from datetime import datetime

try:
    import markdown
except ImportError:
    sys.exit("需要 markdown 模块: python -m pip install markdown pygments")

HERE = os.path.dirname(os.path.abspath(__file__))

DOCS = [
    ("README.md", "分析报告"),
    ("TEST-PLAN.md", "测试执行方案"),
    (os.path.join("scripts", "README.md"), "脚本说明"),
]

TITLE = "OceanBase on Azure v6 存储 I/O 抖动韧性分析与最佳实践"

CSS = """
:root{
  --bg:#ffffff; --fg:#1f2328; --muted:#59636e; --line:#d1d9e0;
  --accent:#0969da; --accent-soft:#ddf4ff;
  --code-bg:#f6f8fa; --table-alt:#f6f8fa;
  --warn-bg:#fff8c5; --warn-line:#d4a72c;
  --sidebar:#f6f8fa;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#0d1117; --fg:#e6edf3; --muted:#9198a1; --line:#3d444d;
    --accent:#4493f8; --accent-soft:#121d2f;
    --code-bg:#161b22; --table-alt:#161b22;
    --warn-bg:#282215; --warn-line:#9e6a03;
    --sidebar:#010409;
  }
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{
  margin:0; background:var(--bg); color:var(--fg);
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei","PingFang SC",
              "Hiragino Sans GB",Helvetica,Arial,sans-serif;
  font-size:15px; line-height:1.7;
}
.layout{display:flex; align-items:flex-start; max-width:1500px; margin:0 auto;}
nav.toc{
  position:sticky; top:0; flex:0 0 290px; max-height:100vh; overflow-y:auto;
  padding:24px 16px 60px; background:var(--sidebar); border-right:1px solid var(--line);
  font-size:13px;
}
nav.toc .toc-head{font-weight:600;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:18px 0 8px}
nav.toc .toc-head:first-child{margin-top:0}
nav.toc ul{list-style:none;margin:0;padding-left:12px}
nav.toc>ul{padding-left:0}
nav.toc li{margin:1px 0}
nav.toc a{display:block;padding:3px 8px;border-radius:5px;color:var(--muted);text-decoration:none;
          overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
nav.toc a:hover{background:var(--accent-soft);color:var(--accent)}
main{flex:1 1 auto; min-width:0; padding:36px 48px 120px; max-width:1080px}
header.doc-head{border-bottom:1px solid var(--line); padding-bottom:20px; margin-bottom:30px}
header.doc-head h1{margin:0 0 8px; font-size:27px; line-height:1.35}
header.doc-head .meta{color:var(--muted); font-size:13px}
h1,h2,h3,h4{line-height:1.3; margin:1.8em 0 .7em; font-weight:600}
h2{font-size:22px; border-bottom:1px solid var(--line); padding-bottom:.3em; margin-top:2.4em}
h3{font-size:18px}
h4{font-size:15px}
p{margin:.7em 0}
a{color:var(--accent)}
hr{border:0;border-top:1px solid var(--line);margin:2.4em 0}
code{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
     font-size:85%; background:var(--code-bg); padding:.2em .4em; border-radius:6px}
pre{background:var(--code-bg); border:1px solid var(--line); border-radius:8px;
    padding:14px 16px; overflow-x:auto; font-size:13px; line-height:1.55}
pre code{background:none;padding:0;font-size:100%}
table{border-collapse:collapse; margin:1.1em 0; font-size:13.5px; display:block; overflow-x:auto; max-width:100%}
th,td{border:1px solid var(--line); padding:7px 12px; text-align:left; vertical-align:top}
th{background:var(--table-alt); font-weight:600; white-space:nowrap}
tbody tr:nth-child(2n){background:var(--table-alt)}
blockquote{margin:1.1em 0; padding:.6em 1em; border-left:4px solid var(--warn-line);
           background:var(--warn-bg); border-radius:0 6px 6px 0}
blockquote p{margin:.35em 0}
ul,ol{padding-left:1.6em}
li{margin:.25em 0}
.badge{display:inline-block;font-size:11px;font-weight:600;padding:1px 7px;border-radius:20px;
       vertical-align:1px;white-space:nowrap;border:1px solid transparent}
.b-official{background:#dafbe1;color:#1a7f37;border-color:#1a7f3733}
.b-source  {background:#ddf4ff;color:#0969da;border-color:#0969da33}
.b-measured{background:#fff1e5;color:#bc4c00;border-color:#bc4c0033}
.b-field   {background:#fbefff;color:#8250df;border-color:#8250df33}
.b-community{background:#f6f8fa;color:#59636e;border-color:#59636e33}
.b-todo    {background:#ffebe9;color:#cf222e;border-color:#cf222e33}
@media (prefers-color-scheme: dark){
  .b-official{background:#12261e;color:#3fb950}
  .b-source{background:#121d2f;color:#4493f8}
  .b-measured{background:#2b1a10;color:#db6d28}
  .b-field{background:#221030;color:#a371f7}
  .b-community{background:#161b22;color:#9198a1}
  .b-todo{background:#2d1214;color:#f85149}
}
.doc-sep{margin:80px 0 0; border-top:3px double var(--line); padding-top:0}
footer{margin-top:80px;padding-top:20px;border-top:1px solid var(--line);
       color:var(--muted);font-size:12.5px}
@media (max-width:1080px){
  nav.toc{display:none}
  main{padding:24px 18px 80px}
}
"""

BADGE_MAP = {
    "官方": "b-official",
    "源码": "b-source",
    "实测": "b-measured",
    "现场": "b-field",
    "社区": "b-community",
    "待验证": "b-todo",
    "待实测确认": "b-todo",
}


def badgeify(html_text: str) -> str:
    """把 [官方]/[源码]/... 渲染成彩色徽章，跳过 <pre>/<code> 内部。"""
    parts = re.split(r"(<pre.*?</pre>|<code.*?</code>)", html_text, flags=re.S)
    pattern = re.compile(r"\[(" + "|".join(sorted(BADGE_MAP, key=len, reverse=True)) + r")\]")

    def repl(m):
        key = m.group(1)
        return f'<span class="badge {BADGE_MAP[key]}">{key}</span>'

    for i, chunk in enumerate(parts):
        if chunk.startswith("<pre") or chunk.startswith("<code"):
            continue
        parts[i] = pattern.sub(repl, chunk)
    return "".join(parts)


def slugify(doc_idx: int, text: str) -> str:
    s = re.sub(r"<[^>]+>", "", text)
    s = re.sub(r"[^\w\u4e00-\u9fff]+", "-", s).strip("-").lower()
    return f"d{doc_idx}-{s}" or f"d{doc_idx}-sec"


def build():
    sections = []
    for idx, (rel, label) in enumerate(DOCS):
        path = os.path.join(HERE, rel)
        if not os.path.exists(path):
            print(f"  skip (not found): {rel}")
            continue
        with open(path, encoding="utf-8") as f:
            text = f.read()

        md = markdown.Markdown(
            extensions=["tables", "fenced_code", "codehilite", "attr_list", "sane_lists"],
            extension_configs={"codehilite": {"noclasses": True, "pygments_style": "friendly"}},
        )
        body = md.convert(text)

        # 为 h2/h3 加锚点并收集目录
        toc = []

        def add_anchor(m):
            level, attrs, inner = m.group(1), m.group(2), m.group(3)
            anchor = slugify(idx, inner)
            toc.append((int(level), anchor, re.sub(r"<[^>]+>", "", inner)))
            return f'<h{level} id="{anchor}"{attrs}>{inner}</h{level}>'

        body = re.sub(r"<h([23])([^>]*)>(.*?)</h\1>", add_anchor, body, flags=re.S)
        body = badgeify(body)

        # 文档内首个 h1 转为 h2 层级展示（避免多个 h1）
        sections.append({"label": label, "rel": rel, "body": body, "toc": toc, "idx": idx})
    return sections


def render(sections):
    nav = []
    for sec in sections:
        nav.append(f'<div class="toc-head">{htmlmod.escape(sec["label"])}</div><ul>')
        for level, anchor, text in sec["toc"]:
            pad = "" if level == 2 else ' style="padding-left:14px"'
            nav.append(f'<li{pad}><a href="#{anchor}">{htmlmod.escape(text)}</a></li>')
        nav.append("</ul>")

    bodies = []
    for i, sec in enumerate(sections):
        cls = "doc-sep" if i > 0 else ""
        bodies.append(f'<section class="{cls}">{sec["body"]}</section>')

    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{htmlmod.escape(TITLE)}</title>
<style>{CSS}</style>
</head>
<body>
<div class="layout">
<nav class="toc">{''.join(nav)}</nav>
<main>
<header class="doc-head">
  <h1>{htmlmod.escape(TITLE)}</h1>
  <div class="meta">
    OceanBase 4.3.5.5 &nbsp;·&nbsp; Azure Standard D32s v6 + Premium SSD v2
    &nbsp;·&nbsp; 生成时间 {now}
  </div>
</header>
{''.join(bodies)}
<footer>
  本文档所有事实性陈述均标注证据等级。
  <span class="badge b-official">官方</span> 厂商官方文档 ·
  <span class="badge b-source">源码</span> OceanBase 开源代码 ·
  <span class="badge b-measured">实测</span> 本次测试数据 ·
  <span class="badge b-field">现场</span> 客户现网日志 ·
  <span class="badge b-community">社区</span> 非官方来源 ·
  <span class="badge b-todo">待验证</span> 禁止作为结论使用。
</footer>
</main>
</div>
</body>
</html>
"""


def main():
    sections = build()
    if not sections:
        sys.exit("没有找到任何 Markdown 源文件")
    out_html = render(sections)

    targets = sys.argv[1:] or [HERE]
    for t in targets:
        os.makedirs(t, exist_ok=True)
        dst = os.path.join(t, "OceanBase-Azure-v6-IO-Jitter-Report.html")
        with open(dst, "w", encoding="utf-8") as f:
            f.write(out_html)
        print(f"  写入 {dst}  ({len(out_html):,} 字符)")


if __name__ == "__main__":
    main()
