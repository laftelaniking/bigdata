#!/usr/bin/env bash
#
# Claude Code SessionStart 훅: 세션을 시작할 때 다른 PC 의 최신 내용을 당겨온다.
# 이게 있어야 집에서 쓴 내용을 회사에서 바로 볼 수 있다.
#
# 어떤 경우에도 0 으로 끝난다 — 동기화 실패가 세션을 막아서는 안 된다.
set -uo pipefail

ARCHIVE_DIR="${CLAUDE_ARCHIVE_DIR:-$HOME/claude-archive}"
LOG="$ARCHIVE_DIR/.archive.log"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG" 2>/dev/null || true; }

command -v git >/dev/null 2>&1 || exit 0
[ -d "$ARCHIVE_DIR/.git" ] || exit 0

cd "$ARCHIVE_DIR" || exit 0
branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo main)"

git fetch -q origin "$branch" >/dev/null 2>&1 || { log "pull: fetch 실패"; exit 0; }
git rev-parse -q --verify "origin/$branch" >/dev/null 2>&1 || exit 0

local_sha="$(git rev-parse HEAD 2>/dev/null || echo none)"
remote_sha="$(git rev-parse "origin/$branch" 2>/dev/null || echo none)"
[ "$local_sha" = "$remote_sha" ] && exit 0

# 빨리감기만 한다. 로컬에 아직 안 올라간 커밋이 있으면 건드리지 않는다 —
# 그건 세션이 끝날 때 archive-session.sh 가 리베이스해서 정리한다.
if git merge -q --ff-only "origin/$branch" >/dev/null 2>&1; then
    n="$(git rev-list --count "$local_sha..$remote_sha" 2>/dev/null || echo ?)"
    log "pull: 다른 PC 의 변경 ${n}건을 받았습니다"
else
    log "pull: 빨리감기 불가 — 세션 종료 시 정리됩니다"
fi
exit 0
