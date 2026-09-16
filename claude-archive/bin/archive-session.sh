#!/usr/bin/env bash
#
# Claude Code SessionEnd 훅: 대화 기록을 아카이브 저장소에 커밋·푸시한다.
# stdin 으로 훅 JSON({session_id, transcript_path, cwd, ...})을 받는다.
#
# 어떤 경우에도 0으로 끝난다 — 아카이브 실패가 세션을 방해해서는 안 된다.
set -uo pipefail

ARCHIVE_DIR="${CLAUDE_ARCHIVE_DIR:-$HOME/claude-archive}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$ARCHIVE_DIR/.archive.log"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG" 2>/dev/null || true; }
die() { log "중단: $*"; exit 0; }

command -v jq  >/dev/null 2>&1 || die "jq 없음"
command -v git >/dev/null 2>&1 || die "git 없음"
[ -d "$ARCHIVE_DIR/.git" ] || die "아카이브 저장소 없음: $ARCHIVE_DIR (install.sh 를 먼저 실행하세요)"

payload="$(cat)"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
session="$(printf '%s'  "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s'      "$payload" | jq -r '.cwd // empty')"

[ -n "$transcript" ] || die "transcript_path 없음"
[ -f "$transcript" ] || die "transcript 파일 없음: $transcript"

# 동시 실행 방지 (여러 세션이 동시에 끝날 수 있다)
exec 9>"$ARCHIVE_DIR/.archive.lock"
if command -v flock >/dev/null 2>&1; then
    flock -w 120 9 || die "락 획득 실패"
fi

host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
y="$(date -u +%Y)"; m="$(date -u +%m)"
stamp="$(date -u +%Y-%m-%d_%H%M)"
sid="${session:-nosession}"

# 첫 사용자 발화에서 제목 slug 만들기
# slug 는 jq 안에서 만든다 — jq 문자열은 코드포인트 단위라 한글이 잘리지 않는다
# (cut/awk 는 바이트 단위라 멀티바이트 문자를 깨뜨린다)
slug="$(jq -r -s '
    [ .[] | select(.type=="user")
      | (.message.content // "")
      | if type=="string" then . else "" end ]
    | map(select(length > 0)) | first // ""
    | gsub("[^\\p{Hangul}\\p{Alnum}]+"; " ")
    | sub("^ +"; "") | sub(" +$"; "")
    | .[0:40]
    | sub(" +$"; "")
    | gsub(" +"; "-")
  ' "$transcript" 2>/dev/null)"
[ -n "$slug" ] || slug="session"

base="${stamp}_${host}_${slug}"
md="$ARCHIVE_DIR/chats/$y/$m/${base}.md"
raw="$ARCHIVE_DIR/raw/$y/$m/${sid}.jsonl"
mkdir -p "$(dirname "$md")" "$(dirname "$raw")"

# 흔한 비밀값 패턴을 마스킹한다 (완벽하지 않음 — README 의 주의사항 참고)
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
    printf -- 'cwd: %s\n' "${cwd:-unknown}"
    printf -- 'archived_at: %s\n' "$now"
    printf -- 'raw: raw/%s/%s/%s.jsonl\n' "$y" "$m" "$sid"
    printf -- '---\n\n'
    "$HERE/jsonl-to-md.sh" "$transcript" 2>/dev/null | redact
} >"$md" || die "마크다운 생성 실패"

# 대화 내용이 없으면 (도구만 돌린 세션 등) 버린다
if [ "$(wc -l <"$md")" -lt 10 ]; then
    rm -f "$md" "$raw"
    die "내용 없음 — 건너뜀 ($sid)"
fi

cd "$ARCHIVE_DIR" || die "cd 실패"
# 리베이스도 커밋을 새로 쓰므로 신원이 필요하다. 커밋에만 넘기면
# 신원이 설정되지 않은 PC 에서 리베이스가 조용히 실패하고 푸시가 영영 막힌다.
ID=(-c user.name="claude-archive" -c user.email="claude-archive@localhost")

git add -A chats raw >/dev/null 2>&1
git diff --cached --quiet && die "변경 없음"
git "${ID[@]}" commit -q -m "archive: ${slug} (${host}, ${stamp})" >/dev/null 2>&1 \
    || die "커밋 실패"

branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo main)"
delay=2
for attempt in 1 2 3 4 5; do
    git fetch -q origin "$branch" >/dev/null 2>&1
    if git rev-parse -q --verify "origin/$branch" >/dev/null 2>&1; then
        # 우리 커밋을 원격 위로 다시 얹는다. 충돌하면(같은 세션을 두 번 저장한 경우 등)
        # 우리 쪽 내용을 택한다 — 리베이스 중에는 replay 되는 우리 커밋이 "theirs" 다.
        git "${ID[@]}" rebase -q "origin/$branch" >/dev/null 2>&1 \
            || { git rebase --abort >/dev/null 2>&1
                 git "${ID[@]}" rebase -q -X theirs "origin/$branch" >/dev/null 2>&1 \
                    || git rebase --abort >/dev/null 2>&1; }
    fi
    if git push -q -u origin "$branch" >/dev/null 2>&1; then
        log "푸시 성공 ($base, 시도 $attempt)"
        exit 0
    fi
    log "푸시 실패 (시도 $attempt) — ${delay}초 후 재시도"
    sleep "$delay"; delay=$((delay*2))
done

log "푸시 최종 실패 — 커밋은 로컬에 남아 있음 ($base)"
exit 0
