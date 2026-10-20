#!/usr/bin/env bash
# 从上游 PCL-Community/PCL-CE 同步 dev 分支。
#
# 做法：按 .github/upstream-sync-base 记录的上游基线逐条 cherry-pick，
# 跳过被剔除的提交和仅修改 GitHub Actions 工作流的上游提交；
# 推送前运行 scripts/check-policy.sh，失败则不推送。
#
# 用法：
#   ./scripts/sync-upstream.sh                 # 同步并推送 origin/dev
#   DRY_RUN=1 ./scripts/sync-upstream.sh       # 演练：提交到当前分支但不推送
#   PUSH=0 ./scripts/sync-upstream.sh          # 本地提交但不推送
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/PCL-Community/PCL-CE.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-dev}"
TARGET_BRANCH="${TARGET_BRANCH:-dev}"
FORBIDDEN_COMMIT="${FORBIDDEN_COMMIT:-8cd9d37491f08e1f8365622517aefed429b5e095}"
STATE_FILE="${STATE_FILE:-.github/upstream-sync-base}"
DRY_RUN="${DRY_RUN:-0}"
PUSH="${PUSH:-1}"

ANON_NAME="${SYNC_GIT_NAME:-4sjUnKY3tB7U12}"
ANON_EMAIL="${SYNC_GIT_EMAIL:-you@know.who}"
export GIT_AUTHOR_NAME="$ANON_NAME"
export GIT_AUTHOR_EMAIL="$ANON_EMAIL"
export GIT_COMMITTER_NAME="$ANON_NAME"
export GIT_COMMITTER_EMAIL="$ANON_EMAIL"
export ANON_EMAIL
export GIT_TERMINAL_PROMPT=0

log() { printf '[sync] %s\n' "$*"; }
die() { printf '[sync] 错误：%s\n' "$*" >&2; exit 1; }

START_HEAD="$(git rev-parse HEAD)"
PUSHED=0
cleanup() {
  local code=$?
  if (( code != 0 && PUSHED == 0 )); then
    git cherry-pick --abort >/dev/null 2>&1 || true
    git reset --hard "$START_HEAD" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

[[ -z "$(git status --porcelain)" ]] || die "工作区不干净，停止同步"

git fetch --no-tags "$UPSTREAM_URL" \
  "+refs/heads/${UPSTREAM_BRANCH}:refs/remotes/upstream/${UPSTREAM_BRANCH}"
UPSTREAM_REF="refs/remotes/upstream/${UPSTREAM_BRANCH}"
UPSTREAM_SHA="$(git rev-parse "$UPSTREAM_REF")"

if [[ -f "$STATE_FILE" ]]; then
  STATE_BASE="$(tr -d '[:space:]' < "$STATE_FILE")"
else
  STATE_BASE="$(git merge-base HEAD "$UPSTREAM_REF")"
  log "未找到 $STATE_FILE，使用 merge-base ${STATE_BASE:0:12}"
fi

[[ "$STATE_BASE" =~ ^[0-9a-f]{40}$ ]] || die "同步基线格式无效：$STATE_BASE"
git cat-file -e "${STATE_BASE}^{commit}" 2>/dev/null || die "同步基线不存在：$STATE_BASE"
git merge-base --is-ancestor "$STATE_BASE" "$UPSTREAM_REF" \
  || die "上游历史可能被重写：基线 $STATE_BASE 不在 $UPSTREAM_REF 上，需人工处理"

if [[ "$STATE_BASE" == "$UPSTREAM_SHA" ]]; then
  log "上游没有新提交（${UPSTREAM_SHA:0:12}）"
  ./scripts/check-policy.sh
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "changed=false" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if [[ -n "$(git rev-list --merges "${STATE_BASE}..${UPSTREAM_REF}")" ]]; then
  die "上游范围内包含合并提交，自动 cherry-pick 不安全，需人工同步"
fi

./scripts/check-policy.sh

mapfile -t COMMITS < <(git rev-list --reverse "${STATE_BASE}..${UPSTREAM_REF}")
log "待处理 ${#COMMITS[@]} 个上游提交（${STATE_BASE:0:12}..${UPSTREAM_SHA:0:12}）"

APPLIED=0
SKIPPED=0
for commit in "${COMMITS[@]}"; do
  subject="$(git show -s --format=%s "$commit")"
  short="${commit:0:12}"
  changed_paths="$(git diff-tree --no-commit-id --name-only -r "$commit")"

  if [[ "$commit" == "$FORBIDDEN_COMMIT" ]]; then
    log "跳过被剔除提交 $short $subject"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # 上游若改写提交哈希，仍按新增文件识别被剔除的功能。
  if grep -qE '^(PCL\.Core/App/Region/RegionPolicy\.cs|Plain Craft Launcher 2/Modules/Minecraft/RestrictedFeaturePolicy\.cs|PCL\.Core\.Test/RegionPolicyTest\.cs)$' <<< "$changed_paths"; then
    log "跳过被剔除功能的相关提交 $short $subject"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # 本 fork 使用自己的 CI，上游仅改工作流的提交没有同步价值。
  if [[ -n "$changed_paths" ]] && ! grep -qvE '^\.github/workflows/' <<< "$changed_paths"; then
    log "跳过仅修改工作流的上游提交 $short $subject"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "应用 $short $subject"
  if ! git cherry-pick --no-commit "$commit"; then
    printf '\n冲突文件：\n' >&2
    git status --porcelain >&2 || true
    die "cherry-pick 冲突：$short $subject"
  fi

  if git diff --cached --quiet; then
    log "改动已存在或为空，跳过 $short"
    git reset --hard HEAD >/dev/null
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # -C 保留原作者与提交信息；这里不加 -x，避免把上游提交哈希写进信息。
  # 显式关闭签名，避免本机全局 commit.gpgsign=true 把真实密钥带进匿名提交。
  git -c commit.gpgsign=false commit -C "$commit" --no-verify >/dev/null
  APPLIED=$((APPLIED + 1))
done

# 即使全部跳过也推进基线，避免每次重复评估同一批提交。
printf '%s\n' "$UPSTREAM_SHA" > "$STATE_FILE"
git add "$STATE_FILE"
if ! git diff --cached --quiet -- "$STATE_FILE"; then
  git -c commit.gpgsign=false commit -m "chore(sync): 记录上游基线 ${UPSTREAM_SHA:0:12}" --no-verify >/dev/null
fi

./scripts/check-policy.sh

log "完成：应用 $APPLIED 个，跳过 $SKIPPED 个，HEAD $(git rev-parse --short HEAD)"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if (( APPLIED > 0 )); then
    echo "changed=true" >> "$GITHUB_OUTPUT"
  else
    echo "changed=false" >> "$GITHUB_OUTPUT"
  fi
fi

if [[ "$DRY_RUN" == "1" || "$PUSH" == "0" ]]; then
  log "DRY_RUN=$DRY_RUN PUSH=$PUSH，不推送"
  exit 0
fi

git push origin "HEAD:${TARGET_BRANCH}"
PUSHED=1
log "已推送 origin/${TARGET_BRANCH}"
