#!/bin/sh
# ============================================================
# KSDoubleTap 一键初始化 + 推送到远程仓库
# 用法:  sh push.sh <仓库地址> [分支名]
# 示例:  sh push.sh https://github.com/you/KSDoubleTap.git main
# ============================================================
set -e

REPO="$1"
BRANCH="${2:-main}"

if [ -z "$REPO" ]; then
  echo "用法: sh push.sh <仓库地址> [分支名]"
  echo "示例: sh push.sh https://github.com/you/KSDoubleTap.git main"
  exit 1
fi

cd "$(dirname "$0")"

# 清理可能已存在的 .git
[ -d .git ] && rm -rf .git

git init -b "$BRANCH"
git config user.name  "${GIT_NAME:-minis}"
git config user.email "${GIT_EMAIL:-minis@users.noreply.github.com}"

git add -A
git commit -m "feat: 快手播放页双击打开评论区 tweak (iOS15+, rootless)

- 拦截播放页双击点赞，改为打开评论区
- 取消双击爱心动画 (CALayer addAnimation 过滤)
- 仅视频播放页生效 (responder 链 + 视图层级判定)
- [KSDT] 全链路日志
- 野指针防护: 指针校验 + @try/@catch + 弱引用延迟处理
- 无私有类名硬依赖，快手任意版本可加载"

git remote add origin "$REPO"
git push -u origin "$BRANCH"

echo ""
echo "✅ 推送完成: $REPO ($BRANCH)"
