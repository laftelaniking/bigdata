#!/usr/bin/env bash
# transcript(.jsonl) -> 읽기 좋은 마크다운
# usage: jsonl-to-md.sh <transcript.jsonl>
set -uo pipefail

src="${1:?usage: jsonl-to-md.sh <transcript.jsonl>}"
[ -f "$src" ] || { echo "no such file: $src" >&2; exit 1; }

jq -r -s '
  # 사용자/어시스턴트의 텍스트 발화만 추출 (도구 호출·도구 결과는 제외)
  def text_of:
    if type == "string" then .
    elif type == "array" then ([.[] | select(.type? == "text") | .text] | join("\n"))
    else "" end;

  [ .[]
    | select(.type == "user" or .type == "assistant")
    | { role: .type,
        ts: (.timestamp // ""),
        text: (.message.content // "" | text_of) }
    | select(.text | length > 0)
  ] as $turns
  |
  ($turns | map(select(.role == "user")) | first | .text // "(제목 없음)") as $first
  |
  "# " + ($first | split("\n")[0] | .[0:60]) + "\n" +
  "\n" +
  ($turns | map(
     (if .role == "user" then "## 나" else "## Claude" end)
     + (if .ts != "" then "  `" + .ts + "`" else "" end)
     + "\n\n" + .text + "\n"
   ) | join("\n"))
' "$src"
