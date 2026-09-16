#!/usr/bin/env bash
#
# Claude Code 대화 자동 아카이브 설치 — PC 마다 한 번만 실행한다.
#
#   첫 PC:      ./install.sh git@github.com:<사용자>/claude-archive.git
#   다른 PC:    git clone <아카이브저장소> ~/claude-archive && ~/claude-archive/install.sh
#
set -euo pipefail

ARCHIVE_DIR="${CLAUDE_ARCHIVE_DIR:-$HOME/claude-archive}"
SETTINGS="$HOME/.claude/settings.json"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${1:-}"

info() { printf '  %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

echo
echo "Claude Code 대화 자동 아카이브 설치"
echo "───────────────────────────────────"

command -v jq  >/dev/null 2>&1 || fail "jq 가 필요합니다.  (mac: brew install jq / ubuntu: apt install jq / win: winget install jqlang.jq)"
command -v git >/dev/null 2>&1 || fail "git 이 필요합니다."

# 1) 아카이브 저장소 준비
if [ -d "$ARCHIVE_DIR/.git" ]; then
    ok "아카이브 저장소가 이미 있습니다: $ARCHIVE_DIR"
elif [ -n "$REPO_URL" ]; then
    info "저장소를 받는 중: $REPO_URL"
    git clone "$REPO_URL" "$ARCHIVE_DIR" || fail "clone 실패 — URL 과 접근 권한을 확인하세요."
    ok "받았습니다: $ARCHIVE_DIR"
else
    fail "아카이브 저장소가 없습니다. 저장소 URL 을 인자로 주세요:
      ./install.sh git@github.com:<사용자>/claude-archive.git"
fi

cd "$ARCHIVE_DIR"

# 현재 브랜치 결정 (아직 커밋이 없는 빈 저장소도 처리한다)
branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
if [ -z "$branch" ]; then
    git checkout -q -b main
    branch=main
fi

# 2) 스크립트를 아카이브 저장소 안으로 복사 (저장소가 곧 배포 수단이 된다)
if [ "$KIT" != "$ARCHIVE_DIR" ]; then
    mkdir -p "$ARCHIVE_DIR/bin"
    cp "$KIT/bin/archive-session.sh" "$KIT/bin/jsonl-to-md.sh" "$ARCHIVE_DIR/bin/"
    cp "$KIT/install.sh" "$ARCHIVE_DIR/install.sh"
    if [ -f "$KIT/README.md" ]; then cp "$KIT/README.md" "$ARCHIVE_DIR/README.md"; fi
    chmod +x "$ARCHIVE_DIR/bin/"*.sh "$ARCHIVE_DIR/install.sh"
fi

mkdir -p "$ARCHIVE_DIR/chats" "$ARCHIVE_DIR/raw"
cat > "$ARCHIVE_DIR/.gitignore" <<'EOF'
.archive.log
.archive.lock
EOF

if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git -c user.name="claude-archive" -c user.email="claude-archive@localhost" \
        commit -q -m "setup: 아카이브 스크립트 설치 ($(hostname -s 2>/dev/null || echo pc))"
    if git push -q -u origin "$branch" 2>/dev/null; then
        ok "저장소에 스크립트를 올렸습니다."
    else
        info "푸시는 나중에 하세요:  cd $ARCHIVE_DIR && git push -u origin $branch"
    fi
fi

# 3) SessionEnd 훅 등록 (기존 설정을 보존하며 병합)
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

jq empty "$SETTINGS" 2>/dev/null || fail "$SETTINGS 의 JSON 이 깨져 있습니다. 먼저 고쳐주세요."

if [ "$ARCHIVE_DIR" = "$HOME/claude-archive" ]; then
    cmd="\"\$HOME/claude-archive/bin/archive-session.sh\""
else
    cmd="\"$ARCHIVE_DIR/bin/archive-session.sh\""
fi

if jq -e --arg c "archive-session.sh" '
      [ (.hooks.SessionEnd // [])[] | (.hooks // [])[] | (.command // "") ]
      | any(contains($c))
    ' "$SETTINGS" >/dev/null 2>&1; then
    ok "훅이 이미 등록되어 있습니다."
else
    tmp="$(mktemp)"
    jq --arg cmd "$cmd" '
        .hooks //= {} |
        .hooks.SessionEnd //= [] |
        .hooks.SessionEnd += [{
            hooks: [{ type: "command", command: $cmd, async: true, timeout: 120 }]
        }]
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "훅을 등록했습니다: $SETTINGS"
fi

echo
echo "───────────────────────────────────"
echo "  설치 완료."
echo
echo "  이제 이 PC 에서 Claude Code 대화를 마칠 때마다"
echo "  대화가 자동으로 아카이브 저장소에 쌓입니다."
echo
echo "  · 아카이브 위치 : $ARCHIVE_DIR"
echo "  · 동작 기록     : $ARCHIVE_DIR/.archive.log"
echo "  · 훅 확인/해제  : Claude Code 에서 /hooks"
echo
echo "  ※ 이미 실행 중인 Claude Code 는 /hooks 를 한 번 열거나"
echo "     다시 시작해야 훅을 인식합니다."
echo
