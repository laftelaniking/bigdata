#!/usr/bin/env bash
#
# SessionEnd 훅 (클라우드용): 이 세션의 대화를 비공개 아카이브 저장소에 쌓는다.
#
# 로컬 PC 용 claude-archive/bin/archive-session.sh 와 목적은 같지만,
# 클라우드 컨테이너는 세션이 끝나면 사라지므로 상주 폴더를 쓸 수 없다.
# 그래서 매번 얕게 클론하고 → 기록하고 → 푸시하고 → 버린다.
#
# 안전장치: 아카이브 저장소가 **비공개임이 확인되지 않으면 아무것도 쓰지 않는다.**
# 이 저장소(bigdata)는 공개이고 GitHub Pages 로 서비스 중이라, 대화가 실수로
# 여기 섞여 들어가면 전 세계에 공개된다.
#
# 어떤 경우에도 0 으로 끝난다 — 아카이브 실패가 세션을 방해해서는 안 된다.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CLAUDE_ARCHIVE_REPO:-laftelaniking/claude-archive}"
WORK="$(mktemp -d 2>/dev/null || echo /tmp/cloud-archive.$$)"
LOG="${CLAUDE_ARCHIVE_LOG:-/tmp/cloud-archive.log}"

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG" 2>/dev/null || true; }
done_() { rm -rf "$WORK" 2>/dev/null || true; exit 0; }
die()  { log "중단: $*"; done_; }

command -v jq   >/dev/null 2>&1 || die "jq 없음"
command -v git  >/dev/null 2>&1 || die "git 없음"
command -v curl >/dev/null 2>&1 || die "curl 없음"

payload="$(cat)"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
session="$(printf '%s'    "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s'        "$payload" | jq -r '.cwd // empty')"

[ -n "$transcript" ] || die "transcript_path 없음"
[ -f "$transcript" ] || die "transcript 파일 없음: $transcript"

# ── 안전장치 ────────────────────────────────────────────────────────────────
# 대상 저장소가 확실히 비공개일 때만 진행한다. 판단이 안 서면 쓰지 않는다.
vis="$(curl -sS --max-time 20 \
        -H "Authorization: Bearer ${GH_TOKEN:-}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO" 2>/dev/null \
      | jq -r '.private // "unknown"' 2>/dev/null || echo unknown)"

case "$vis" in
    true) : ;;
    false) die "$REPO 는 공개 저장소다 — 대화를 쓰지 않는다" ;;
    *)     die "$REPO 의 공개 여부를 확인할 수 없다 (저장소가 없거나 접근 권한 없음) — 쓰지 않는다" ;;
esac

# ── 클론 ────────────────────────────────────────────────────────────────────
git clone -q --depth 1 "https://github.com/$REPO.git" "$WORK/repo" 2>/dev/null \
    || die "클론 실패: $REPO (이 세션에 푸시 권한이 없을 수 있음)"
DIR="$WORK/repo"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
y="$(date -u +%Y)"; m="$(date -u +%m)"
stamp="$(date -u +%Y-%m-%d_%H%M)"
sid="${session:-nosession}"
host="cloud"   # 클라우드 컨테이너는 호스트명이 매번 달라 의미가 없다

# 첫 사용자 발화에서 제목 slug (jq 안에서 만든다 — 한글이 바이트 단위로 잘리지 않도록)
slug="$(jq -r -s '
    [ .[] | select(.type=="user")
      | (.message.content // "")
      | if type=="string" then . else "" end ]
    | map(select(length > 0)) | first // ""
    | gsub("[^\\p{Hangul}\\p{Alnum}]+"; " ")
    | sub("^ +"; "") | sub(" +$"; "")
    | .[0:40] | sub(" +$"; "") | gsub(" +"; "-")
  ' "$transcript" 2>/dev/null)"
[ -n "$slug" ] || slug="session"

base="${stamp}_${host}_${slug}"
md="$DIR/chats/$y/$m/${base}.md"
raw="$DIR/raw/$y/$m/${sid}.jsonl"
mkdir -p "$(dirname "$md")" "$(dirname "$raw")"

# 흔한 비밀값 패턴 마스킹 (완벽하지 않다 — 저장소를 비공개로 두는 것이 본 방어선)
redact() {
    sed -E \
      -e 's/sk-ant-[A-Za-z0-9_-]{16,}/[REDACTED-ANTHROPIC-KEY]/g' \
      -e 's/ghp_[A-Za-z0-9]{20,}/[REDACTED-GITHUB-TOKEN]/g' \
      -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED-GITHUB-TOKEN]/g' \
      -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g' \
      -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED-SLACK-TOKEN]/g' \
      -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED-PRIVATE-KEY]/g'
}

redact <"$transcript" >"$raw" 2>/dev/null || die "raw 복사 실패"

{
    printf -- '---\n'
    printf -- 'session: %s\n' "$sid"
    printf -- 'machine: %s\n' "$host"
    printf -- 'origin: cloud\n'
    printf -- 'cwd: %s\n' "${cwd:-unknown}"
    printf -- 'archived_at: %s\n' "$now"
    printf -- 'raw: raw/%s/%s/%s.jsonl\n' "$y" "$m" "$sid"
    printf -- '---\n\n'
    "$HERE/jsonl-to-md.sh" "$transcript" 2>/dev/null | redact
} >"$md" || die "마크다운 생성 실패"

# 내용 없는 세션(도구만 돌린 경우 등)은 버린다
if [ "$(wc -l <"$md")" -lt 10 ]; then
    die "내용 없음 — 건너뜀 ($sid)"
fi

# ── 커밋·푸시 ───────────────────────────────────────────────────────────────
cd "$DIR" || die "cd 실패"
ID=(-c user.name="claude-archive" -c user.email="claude-archive@localhost")

git add -A >/dev/null 2>&1
git diff --cached --quiet && die "변경 없음"
git "${ID[@]}" commit -q -m "archive: ${slug} (cloud, ${stamp})" >/dev/null 2>&1 || die "커밋 실패"

branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo main)"
delay=2
for attempt in 1 2 3 4 5; do
    git fetch -q origin "$branch" >/dev/null 2>&1
    if git rev-parse -q --verify "origin/$branch" >/dev/null 2>&1; then
        git "${ID[@]}" rebase -q "origin/$branch" >/dev/null 2>&1 \
            || { git rebase --abort >/dev/null 2>&1
                 git "${ID[@]}" rebase -q -X theirs "origin/$branch" >/dev/null 2>&1 \
                    || git rebase --abort >/dev/null 2>&1; }
    fi
    if git push -q origin "$branch" >/dev/null 2>&1; then
        log "푸시 성공 ($base, 시도 $attempt)"
        done_
    fi
    log "푸시 실패 (시도 $attempt) — ${delay}초 후 재시도"
    sleep "$delay"; delay=$((delay*2))
done

log "푸시 최종 실패 ($base) — 컨테이너가 사라지면 이 기록은 없어진다"
done_
