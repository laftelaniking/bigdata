# Claude 대화 자동 아카이브

어느 PC에서 Claude Code로 대화하든, 세션이 끝나면 그 대화가 자동으로
git 저장소에 쌓입니다. 집·회사 어디서 작업하든 기록이 한곳에 모입니다.

```
집 PC ─┐
       ├─→ (SessionEnd 훅) ─→ 아카이브 저장소 ─→ 어디서든 열람·검색
회사PC ─┘
```

## 설치

### 준비: 아카이브 저장소 만들기 (한 번만)

GitHub에서 **비공개(Private)** 저장소를 하나 만듭니다. 이름은 `claude-archive`를 권합니다.

> **반드시 비공개로 만드세요.** 대화 기록에는 개인적인 내용이 들어갑니다.

### 첫 PC

```bash
git clone <이 저장소> /tmp/kit
/tmp/kit/claude-archive/install.sh git@github.com:<사용자명>/claude-archive.git
```

설치 스크립트가 아카이브 저장소를 `~/claude-archive`에 받고, 필요한 스크립트를
그 안에 넣어 올린 뒤, 훅을 등록합니다.

### 다른 PC

아카이브 저장소에 이미 스크립트가 들어 있으니 이것만 하면 됩니다:

```bash
git clone git@github.com:<사용자명>/claude-archive.git ~/claude-archive
~/claude-archive/install.sh
```

설치 후 실행 중이던 Claude Code는 `/hooks`를 한 번 열거나 재시작해야 훅을 인식합니다.

## 쌓이는 모양

```
claude-archive/
├── chats/2026/09/2026-09-16_0340_집PC_제갈량-말투를-어떻게-잡을까.md   ← 읽기용
└── raw/2026/09/<세션ID>.jsonl                                        ← 원본 전체
```

- **`chats/`** — 사람이 읽는 마크다운. 대화 본문만 담깁니다(도구 호출·결과는 제외).
  파일 첫머리에 세션 ID, 어느 PC였는지, 작업 폴더가 기록됩니다.
- **`raw/`** — 손실 없는 원본. 나중에 무엇이든 다시 뽑아낼 수 있습니다.

## 필요한 것

- `git`, `jq`
  - macOS: `brew install jq`
  - Ubuntu/Debian: `sudo apt install jq`
  - Windows: `winget install jqlang.jq` (Git Bash 또는 WSL에서 실행)
- 해당 PC에서 아카이브 저장소로 **인증 없이 push 가능**해야 합니다
  (SSH 키 또는 credential helper 설정).

## 알아두어야 할 것

**여러 PC에서 동시에 써도 됩니다.** 푸시할 때마다 자동으로 `fetch` + `rebase`를
거치고, 실패하면 2·4·8·16초 간격으로 최대 5번 재시도합니다.

**세션을 붙잡지 않습니다.** 훅은 `async`로 돌아서 Claude Code 종료를 지연시키지 않습니다.
아카이브가 실패해도 세션에는 영향이 없습니다.

**비밀값 마스킹은 보조 수단일 뿐입니다.** 흔한 형태(Anthropic·GitHub·AWS·Slack 토큰,
개인키 머리글)는 자동으로 가려지지만, **모든 비밀값을 잡아내지는 못합니다.**
저장소를 반드시 비공개로 두고, 대화 중 비밀번호·키를 붙여넣지 않는 편이 안전합니다.

**빈 세션은 건너뜁니다.** 대화 없이 도구만 돌린 세션은 저장하지 않습니다.

## 문제가 생기면

동작 기록을 먼저 보세요:

```bash
cat ~/claude-archive/.archive.log
```

| 증상 | 확인할 것 |
|---|---|
| 아무것도 안 쌓임 | `/hooks`에서 훅이 보이는지. 안 보이면 Claude Code 재시작 |
| `jq 없음` | jq 설치 |
| `푸시 최종 실패` | 커밋은 로컬에 남아 있음. `cd ~/claude-archive && git push` 로 수동 푸시 |
| 특정 대화가 없음 | `건너뜀` 기록이 있는지 확인 (내용 없는 세션은 제외됨) |

## 끄기

Claude Code에서 `/hooks`를 열어 SessionEnd 항목을 지우거나,
`~/.claude/settings.json`에서 `archive-session.sh` 항목을 지우면 됩니다.
