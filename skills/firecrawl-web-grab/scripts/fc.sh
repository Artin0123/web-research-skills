#!/usr/bin/env bash
# fc.sh —— Firecrawl search / scrape 精简版（纯 bash，只需 curl + awk + coreutils，不需要 Python / Node / jq）
#
# scrape <url...> [选项]                 多个 URL 时每次 2 个并行，各自存成 .firecrawl/<站点-路径>.md
#   -f <格式>          markdown（默认）| html | links | screenshot | json，可用逗号组合（组合或 json 时存完整 JSON，含 markdown 则另拆出 .md）
#   --schema <json>    配合 -f json 做结构化抽取；写成 @文件 则从文件读取
#   -Q <问题>          针对页面提问，直接输出答案（仅限单一 URL；未指定 -f 时不存页面，指定 -f 则答案与页面都要）
#   --wait-for <ms>    等待 JS 渲染的毫秒数
#   --max-age <ms>     可接受的缓存年龄，0 = 强制重新抓取（API 默认 2 天）
#   --full             保留导航、页脚等（默认只抓主要内容，与 API 默认相同）
#   -o <路径>          单一 URL 的输出文件；- 表示印到 stdout
#
# search "<查询>" [选项]                 结果存到 .firecrawl/search-<查询>/（index.json + 每条全文）
#   --limit <n>                     结果数量（默认 5）
#   --scrape                        同时抓取每条结果的全文（markdown，只抓主要内容）
#   --tbs qdr:h|d|w|m|y             时间范围
#   --country <code>                例如 TW、US
#   --sources web,news              结果来源（默认 web）
#   --include-domains a.com,b.com   只搜这些网站
#   --exclude-domains a.com,b.com   排除这些网站
#
# status                            显示剩余 credits
#
# 选项也可以写成 --name=value。API key 读取 FIRECRAWL_API_KEY，缺少时直接报错退出。

set -f   # 关闭通配符展开，避免逗号列表里的 * ? 被展开

API_URL=${FIRECRAWL_API_URL:-https://api.firecrawl.dev}
API_KEY=${FIRECRAWL_API_KEY:-}
OUTDIR=.firecrawl

die() { printf 'fc.sh: %s\n' "$*" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v awk  >/dev/null 2>&1 || die "awk not found"

T=$(mktemp -d 2>/dev/null || mktemp -d -t fcsh) || die "cannot create temp directory"
trap 'rm -rf "$T"' EXIT
# Windows 原生 curl.exe 看不懂 /tmp/... 这类 MSYS 路径，统一转成 C:/... 形式
if command -v cygpath >/dev/null 2>&1; then TN=$(cygpath -m "$T"); else TN=$T; fi

# ---------------------------------------------------------------- JSON 解析（awk）
# 把 JSON 摊平成「路径<TAB>类型<TAB>原始值」：类型 s=字符串(保留转义) l=数字/布尔/null o={} a=[]
# 例：.data.web[0].url<TAB>s<TAB>https://...
FLATTEN_AWK='
BEGIN { RS = "\001" }
{ s = s $0 }
END { n = length(s); p = 1; bad = 0; ws(); if (p > n) exit 3; pval(""); ws(); if (p <= n) bad = 2; exit bad }
function ws(   c) { while (p <= n) { c = substr(s, p, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") p++; else break } }
function fail() { bad = 2; p = n + 1 }
function pval(path,   c, st) {
  ws(); c = substr(s, p, 1)
  if (c == "{") pobj(path)
  else if (c == "[") parr(path)
  else if (c == "\"") printf "%s\ts\t%s\n", path, pstr()
  else {
    st = p
    while (p <= n) { c = substr(s, p, 1); if (c == "," || c == "]" || c == "}" || c == " " || c == "\t" || c == "\n" || c == "\r") break; p++ }
    c = substr(s, st, p - st)
    if (c !~ /^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?)$/) { fail(); return }
    printf "%s\tl\t%s\n", path, c
  }
}
function pobj(path,   k, c) {
  p++; ws()
  if (substr(s, p, 1) == "}") { p++; printf "%s\to\t{}\n", path; return }
  while (p <= n) {
    ws(); if (substr(s, p, 1) != "\"") { fail(); return }
    k = pstr(); ws()
    if (substr(s, p, 1) != ":") { fail(); return }
    p++; pval(path "." k); ws()
    c = substr(s, p, 1); p++
    if (c == "}") return
    if (c != ",") { fail(); return }
  }
  fail()
}
function parr(path,   i, c) {
  p++; ws()
  if (substr(s, p, 1) == "]") { p++; printf "%s\ta\t[]\n", path; return }
  i = 0
  while (p <= n) {
    pval(path "[" i "]"); i++; ws()
    c = substr(s, p, 1); p++
    if (c == "]") return
    if (c != ",") { fail(); return }
  }
  fail()
}
function pstr(   st, c) {
  p++; st = p
  while (p <= n) {
    c = substr(s, p, 1)
    if (c == "\\") p += 2
    else if (c == "\"") { p++; return substr(s, st, p - 1 - st) }
    else p++
  }
  fail(); return ""
}'

# 把 JSON 字符串的转义还原成 UTF-8 字节（含 \uXXXX 与代理对）；sep 为每条记录后的分隔
DECODE_AWK='
BEGIN { H = "0123456789abcdef" }
function hex4(h,   i, v) { h = tolower(h); v = 0; for (i = 1; i <= 4; i++) v = v * 16 + index(H, substr(h, i, 1)) - 1; return v }
function u8(c) {
  if (c < 128) return sprintf("%c", c)
  if (c < 2048) return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
  if (c < 65536) return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
  return sprintf("%c%c%c%c", 240 + int(c / 262144), 128 + int(c / 4096) % 64, 128 + int(c / 64) % 64, 128 + c % 64)
}
{
  m = split($0, a, /\\/)
  printf "%s", a[1]
  k = 2
  while (k <= m) {
    t = a[k]
    if (t == "") { printf "\\"; k++; if (k <= m) printf "%s", a[k]; k++; continue }
    e = substr(t, 1, 1); r = substr(t, 2)
    if (e == "n") printf "\n%s", r
    else if (e == "t") printf "\t%s", r
    else if (e == "r") printf "\r%s", r
    else if (e == "b") printf "\b%s", r
    else if (e == "f") printf "\f%s", r
    else if (e == "u") {
      cp = hex4(substr(t, 2, 4)); r = substr(t, 6)
      if (cp >= 55296 && cp < 56320 && r == "" && k < m && substr(a[k + 1], 1, 1) == "u") {
        lo = hex4(substr(a[k + 1], 2, 4))
        if (lo >= 56320 && lo < 57344) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); k++; r = substr(a[k], 6) }
      }
      if (cp > 0) printf "%s", u8(cp)
      printf "%s", r
    }
    else printf "%s%s", e, r
    k++
  }
  printf "%s", sep
}'

# 按字节截断但不切坏 UTF-8 字符，超过时加后缀 suf（cut_b 默认 ...，传 "" 则不加）
CUT_AWK='
BEGIN { for (i = 0; i < 256; i++) ORD[sprintf("%c", i)] = i }
{
  if (length($0) <= n) { print; next }
  x = substr($0, 1, n)
  while (length(x) && (c = ORD[substr(x, length(x), 1)]) >= 128 && c < 192) x = substr(x, 1, length(x) - 1)
  if (length(x) && ORD[substr(x, length(x), 1)] >= 192) x = substr(x, 1, length(x) - 1)
  print x suf
}'

flat()   { LC_ALL=C awk "$FLATTEN_AWK" "$1" > "$2"; }
jhas()   { LC_ALL=C awk -F'\t' -v p="$1" '$1 == p { f = 1; exit } END { exit !f }' "$FLAT"; }
jraw()   { LC_ALL=C awk -F'\t' -v p="$1" '$1 == p { print $3; exit }' "$FLAT"; }
jget()   { jraw "$1" | LC_ALL=C awk -v sep="" "$DECODE_AWK"; }
jlist()  { LC_ALL=C awk -F'\t' -v p="$1" 'index($1, p "[") == 1 && substr($1, length(p) + 1) ~ /^\[[0-9]+\]$/ { print $3 }' "$FLAT" \
           | LC_ALL=C awk -v sep='\n' "$DECODE_AWK"; }
cut_b()  { LC_ALL=C awk -v n="$1" -v suf="${2-...}" "$CUT_AWK"; }
nchars() { LC_ALL=C tr -d '\200-\277' < "$1" | wc -c | tr -d ' '; }   # UTF-8 字符数

# ---------------------------------------------------------------- JSON 构造与参数工具
jstr() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}
trim() { local x=$1; x=${x#"${x%%[![:space:]]*}"}; x=${x%"${x##*[![:space:]]}"}; printf '%s' "$x"; }
# "a, b" -> ["a","b"]；第二个参数非空时包成 [{"type":"a"},...]
jarr() {
  local IFS=, x out="" v
  for x in $1; do
    x=$(trim "$x"); [ -n "$x" ] || continue
    if [ -n "${2:-}" ]; then v="{\"type\":$(jstr "$x")}"; else v=$(jstr "$x"); fi
    out="$out${out:+,}$v"
  done
  printf '[%s]' "$out"
}
isjson() { printf '%s' "$1" | LC_ALL=C awk "$FLATTEN_AWK" >/dev/null 2>&1; }
need()   { [ "$#" -ge 2 ] || die "$1 requires a value"; }
chkint() { case $2 in ''|*[!0-9]*) die "$1 requires a non-negative integer (got: $2)";; esac; }

# ---------------------------------------------------------------- HTTP
req() {  # req 方法 路径 请求体文件(可空) 响应文件 -> 输出 "HTTP码 秒数"；网络错误返回 1
  [ -f "$T/hdr" ] || printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$API_KEY" > "$T/hdr"
  local a=(-sS --connect-timeout 30 -X "$1" -H "@$TN/hdr" -o "$TN/${4##*/}" -w '%{http_code} %{time_total}')
  [ -n "$3" ] && a+=(--data-binary "@$TN/${3##*/}")
  local r code n=0 w
  # 429 / 5xx / 连线失败最多重试 2 次；429 依错误信息里的「retry after Ns」等待（上限 65 秒）
  while :; do
    r=$(curl "${a[@]}" "${API_URL%/}$2") || r="000 0"
    code=${r% *}
    case $code in 429|500|502|503|504|000) ;; *) break;; esac
    [ "$n" -lt 2 ] || break
    w=5
    if [ "$code" = 429 ]; then
      w=$(sed -n 's/.*retry after \([0-9][0-9]*\)s.*/\1/p' "$4" 2>/dev/null | head -1)
      w=$(( ${w:-10} + 1 )); [ "$w" -le 65 ] || w=65
    fi
    printf 'fc.sh: HTTP %s, retrying in %ss (%s/2)\n' "$code" "$w" "$((n + 1))" >&2
    sleep "$w"; n=$((n + 1))
  done
  [ "$code" != 000 ] || return 1
  printf '%s' "$r"
}
check() {  # check HTTP码 响应文件 标签：摊平到 $FLAT，失败时把错误写到 stderr 并返回 1
  if ! flat "$2" "$FLAT"; then
    printf 'fc.sh: %s HTTP %s, non-JSON response: %s\n' "$3" "$1" "$(head -c 200 "$2")" >&2; return 1
  fi
  if [ "$1" -ge 400 ] || [ "$(jraw .success)" = false ]; then
    printf 'fc.sh: %s HTTP %s: %s\n' "$3" "$1" "$(jget .error)" >&2; return 1
  fi
}

# ---------------------------------------------------------------- 文件
# https://www.a.com/x/y?b=1 -> a.com-x-y-b-1
urlbase() {
  local u=${1#*://} host rest
  host=${u%%[/?#]*}; rest=${u#"$host"}; host=${host#www.}; rest=${rest%%#*}
  printf '%s' "$host${rest:+-$rest}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | tr -s '-' | cut_b 120 "" | sed 's/-*$//'
}
qslug() {  # 保留中文等非 ASCII 字符
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._\200-\377-' '-' | tr -s '-' | cut_b 60 "" | sed 's/^-*//; s/-*$//'
}
noext() {  # 只去掉最后一段路径的扩展名：.firecrawl/a.md -> .firecrawl/a
  local d="" b=$1
  case $1 in */*) d=${1%/*}/; b=${1##*/};; esac
  case $b in ?*.*) b=${b%.*};; esac
  printf '%s' "$d$b"
}
put() {  # put 来源文件 目标路径
  case $2 in */*) mkdir -p "${2%/*}";; esac
  mv -f "$1" "$2"
}
addscheme() { case $1 in *://*) printf '%s' "$1";; *) printf 'https://%s' "$1";; esac; }

# ================================================================ scrape
cmd_scrape() {
  local urls=() fmts="" schema="" query="" wait="" maxage="" full=false out="" x f
  while [ "$#" -gt 0 ]; do
    case $1 in
      --*=*) x=$1; shift; set -- "${x%%=*}" "${x#*=}" "$@"; continue;;
      -f) need "$@"; fmts=$2; shift 2;;
      --schema) need "$@"; schema=$2; shift 2;;
      -Q) need "$@"; query=$2; shift 2;;
      --wait-for) need "$@"; chkint "$1" "$2"; wait=$2; shift 2;;
      --max-age) need "$@"; chkint "$1" "$2"; maxage=$2; shift 2;;
      --full) full=true; shift;;
      -o) need "$@"; out=$2; shift 2;;
      -*) die "scrape: unknown option $1";;
      *) urls+=("$1"); shift;;
    esac
  done
  [ "${#urls[@]}" -gt 0 ] || die "usage: fc.sh scrape <url...> [-f formats] [--schema json|@file] [-Q question] [--wait-for ms] [--max-age ms] [--full] [-o path|-]"
  case $schema in @*) [ -f "${schema#@}" ] || die "file not found: ${schema#@}"; schema=$(cat "${schema#@}");; esac
  [ -z "$schema" ] || isjson "$schema" || die "--schema is not valid JSON"

  # ---- formats（fset 记录是否显式指定过 -f）
  local fset=$fmts; fmts=${fmts:-markdown}
  local names=() fj="" IFS=,
  for f in $fmts; do
    f=$(trim "$f"); [ -n "$f" ] || continue
    case $f in markdown|html|links|screenshot|json) ;; *) die "unsupported format $f (available: markdown html links screenshot json)";; esac
    case " ${names[*]} " in *" $f "*) continue;; esac
    names+=("$f")
  done
  unset IFS
  [ -n "$query" ] && [ -z "$fset" ] && names=()   # 只提问且没指定 -f 时不必再拿 markdown
  for f in "${names[@]}"; do
    if [ "$f" = json ]; then
      [ -n "$schema" ] || die "-f json requires --schema"
      x="{\"type\":\"json\",\"schema\":$schema}"
    else x="\"$f\""; fi
    fj="$fj${fj:+,}$x"
  done
  [ -n "$query" ] && fj="$fj${fj:+,}{\"type\":\"question\",\"question\":$(jstr "$query")}"
  [ -n "$fj" ] || die "no format specified"

  local rest="\"formats\":[$fj]"
  $full && rest="$rest,\"onlyMainContent\":false"
  [ -n "$wait" ]   && rest="$rest,\"waitFor\":$wait"
  [ -n "$maxage" ] && rest="$rest,\"maxAge\":$maxage"

  if [ "${#urls[@]}" -eq 1 ]; then
    scrape_single "${urls[0]}" "$rest" "$out" "$query" "${names[@]}"
    return
  fi
  [ -z "$query" ] || die "-Q supports a single URL only"
  [ -z "$out" ] || die "-o is not supported with multiple URLs (each is saved under $OUTDIR/)"
  [ "${names[*]}" = markdown ] || die "multiple URLs support markdown only"
  local i=0 fails=0
  echo "Scraping ${#urls[@]} URLs, 2 at a time..."
  for x in "${urls[@]}"; do
    scrape_multi "$x" "$rest" "$i" > "$T/sum$i" 2>&1 &
    i=$((i + 1)); [ $((i % 2)) -eq 0 ] && wait
  done
  wait
  i=0; for x in "${urls[@]}"; do cat "$T/sum$i"; grep -q '^ERR' "$T/sum$i" && fails=$((fails + 1)); i=$((i + 1)); done
  echo "Completed: $(( ${#urls[@]} - fails ))/${#urls[@]} succeeded"
  [ "$fails" -lt "${#urls[@]}" ] || exit 1
}

# 请求一次 scrape，摊平结果写到 $FLAT（调用方须先设好 FLAT，因为这里常在子 shell 里跑），输出 "HTTP码 秒数"
scrape_req() {  # scrape_req url rest tag
  printf '{"url":%s,%s}' "$(jstr "$(addscheme "$1")")" "$2" > "$T/body$3"
  local r; r=$(req POST /v2/scrape "$T/body$3" "$T/resp$3") || { echo "fc.sh: $1 network error" >&2; return 1; }
  check "${r% *}" "$T/resp$3" "$1" || return 1
  printf '%s' "$r"
}
meta_line() {  # meta_line 秒数
  local w; w=$(jget .data.warning)
  printf 'status=%s credits=%s cache=%s time=%ss%s' \
    "$(jraw .data.metadata.statusCode)" "$(jraw .data.metadata.creditsUsed)" "$(jraw .data.metadata.cacheState)" "$1" "${w:+ warning=$w}"
}

scrape_multi() {  # scrape_multi url rest tag
  local r f
  FLAT="$T/flatm$3"
  r=$(scrape_req "$1" "$2" "m$3") || { echo "ERR $1"; return 1; }
  f="$OUTDIR/$(urlbase "$(addscheme "$1")").md"
  jget .data.markdown > "$T/o$3"; put "$T/o$3" "$f"
  echo "saved $f | chars=$(nchars "$f") $(meta_line "${r#* }")"
}

scrape_single() {  # scrape_single url rest out query names...
  local url=$1 rest=$2 out=$3 query=$4; shift 4
  local r base f x n
  FLAT="$T/flats"
  r=$(scrape_req "$url" "$rest" s) || exit 1
  base="$OUTDIR/$(urlbase "$(addscheme "$url")")"

  if [ -n "$query" ]; then
    if jhas .data.answer; then jget .data.answer; echo; else echo "(no answer field in response)"; fi
    echo "--- $(meta_line "${r#* }")"
    [ "$#" -eq 0 ] && return
  fi

  if [ "$#" -gt 1 ] || [ "$1" = json ]; then set -- multi; fi
  case $1 in
    markdown|html)
      jget ".data.$1" > "$T/o"
      if [ "$1" = html ]; then f=${out:-$base.html}; else f=${out:-$base.md}; fi
      if [ "$f" = - ]; then cat "$T/o"; echo; echo "--- chars=$(nchars "$T/o") $(meta_line "${r#* }")"; return; fi
      put "$T/o" "$f"; echo "saved $f | chars=$(nchars "$f") $(meta_line "${r#* }")";;
    links)
      jlist .data.links > "$T/o"; n=$(wc -l < "$T/o" | tr -d ' '); f=${out:-$base.links.txt}
      if [ "$f" = - ]; then cat "$T/o"; echo "--- links=$n $(meta_line "${r#* }")"; return; fi
      put "$T/o" "$f"; echo "saved $f | links=$n $(meta_line "${r#* }")";;
    screenshot)
      x=$(jget .data.screenshot); f=${out:-$base.png}
      if [ "$f" != - ] && [ "${x#http}" != "$x" ] && curl -sS -o "$TN/shot" "$x"; then
        put "$T/shot" "$f"; echo "saved $f | $(meta_line "${r#* }")"
      else echo "screenshot: ${x:0:200} | $(meta_line "${r#* }")"; fi;;
    multi)  # 多种格式或 json：存完整响应，另外拆出 markdown
      f=${out:-$base.json}
      if [ "$f" = - ]; then cat "$T/resps"; echo; return; fi
      cp "$T/resps" "$T/j"; put "$T/j" "$f"
      x=""; if jhas .data.markdown; then jget .data.markdown > "$T/o"; put "$T/o" "$(noext "$f").md"; x=" + $(noext "$f").md"; fi
      echo "saved $f$x | $(meta_line "${r#* }")";;
  esac
}

# ================================================================ search
cmd_search() {
  local q="" limit=5 sources=web tbs="" country="" inc="" exc="" scrape=false x
  while [ "$#" -gt 0 ]; do
    case $1 in
      --*=*) x=$1; shift; set -- "${x%%=*}" "${x#*=}" "$@"; continue;;
      --limit) need "$@"; chkint "$1" "$2"; limit=$2; shift 2;;
      --scrape) scrape=true; shift;;
      --tbs) need "$@"; tbs=$2; shift 2;;
      --country) need "$@"; country=$2; shift 2;;
      --sources) need "$@"; sources=$2; shift 2;;
      --include-domains) need "$@"; inc=$2; shift 2;;
      --exclude-domains) need "$@"; exc=$2; shift 2;;
      -*) die "search: unknown option $1";;
      *) [ -z "$q" ] || die "only one query string allowed (quote multi-word queries)"; q=$1; shift;;
    esac
  done
  [ -n "$q" ] || die 'usage: fc.sh search "<query>" [--limit n] [--scrape] [--tbs qdr:w] [--country TW] [--sources web,news] [--include-domains a,b] [--exclude-domains a,b]'

  local b="\"query\":$(jstr "$q"),\"limit\":$limit,\"sources\":$(jarr "$sources" t)"
  [ -n "$tbs" ]     && b="$b,\"tbs\":$(jstr "$tbs")"
  [ -n "$country" ] && b="$b,\"country\":$(jstr "$country")"
  [ -n "$inc" ]     && b="$b,\"includeDomains\":$(jarr "$inc")"
  [ -n "$exc" ]     && b="$b,\"excludeDomains\":$(jarr "$exc")"
  $scrape && b="$b,\"scrapeOptions\":{\"formats\":[\"markdown\"]}"
  printf '{%s}' "$b" > "$T/body"

  FLAT="$T/flat"
  local r; r=$(req POST /v2/search "$T/body" "$T/resp") || die "network error"
  check "${r% *}" "$T/resp" search || exit 1

  local dir="$OUTDIR/search-$(qslug "$q")"
  cp "$T/resp" "$T/idx"; put "$T/idx" "$dir/index.json"
  x=$(jget .warning)
  echo "search credits=$(jraw .creditsUsed) time=${r#* }s -> $dir/${x:+ warning=$x}"

  local pre src idx url title f n=0
  for pre in $(LC_ALL=C awk -F'\t' 'match($1, /^\.data\.(web|news)\[[0-9]+\]/) { k = substr($1, RSTART, RLENGTH); if (!(k in seen)) { seen[k] = 1; print k } }' "$FLAT"); do
    n=$((n + 1))
    src=${pre#.data.}; src=${src%%\[*}; idx=${pre##*\[}; idx=$(printf '%02d' $(( ${idx%]} + 1 )))
    url=$(jget "$pre.url")
    title=$(jget "$pre.title" | tr '\n' ' ' | cut_b 100)
    if jhas "$pre.markdown"; then
      f="$dir/$src-$idx.md"; jget "$pre.markdown" > "$T/o"; put "$T/o" "$f"
      echo "  [$src $idx] $url${title:+ - $title} | chars=$(nchars "$f") -> $f"
    else
      echo "  [$src $idx] $url${title:+ - $title}"
      $scrape && echo "      (no full text: unsupported site or scrape failed)"
      x=$(jget "$pre.description" | tr '\n' ' ' | cut_b 200); [ -n "$x" ] && echo "      $x"
    fi
  done
  [ "$n" -gt 0 ] || echo "  (no results)"
}

# ================================================================ status
cmd_status() {
  FLAT="$T/flat"
  local r; r=$(req GET /v2/team/credit-usage "" "$T/resp") || die "network error"
  check "${r% *}" "$T/resp" status || exit 1
  local p=.data; jhas .data.remainingCredits || p=""
  echo "credits remaining=$(jraw "$p.remainingCredits") plan=$(jraw "$p.planCredits") period=$(jget "$p.billingPeriodStart") ~ $(jget "$p.billingPeriodEnd")"
}

# ================================================================ main
cmd=${1:-}; [ "$#" -gt 0 ] && shift
case $cmd in scrape|search|status) [ -n "$API_KEY" ] || die "FIRECRAWL_API_KEY is not set";; esac
case $cmd in
  scrape) cmd_scrape "$@";;
  search) cmd_search "$@";;
  status) cmd_status "$@";;
  *) echo 'fc.sh: usage: fc.sh <scrape|search|status> ... (see header comments)' >&2; exit 2;;
esac
