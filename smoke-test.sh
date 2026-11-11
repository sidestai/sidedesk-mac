#!/bin/bash
# test-mode 冒烟：用 --test-mode 启动一次真实进程，验证「隔离目录 + 启动日志 + 自动退出 + 零副作用」这条链。
# 对应 C# 仓的 E2E 生命周期断言（ADR-0004）。可重复执行，不碰真实数据目录、不发网络请求。
set -uo pipefail

cd "$(dirname "$0")"

APP="dist/SidestMac.app/Contents/MacOS/SidestMac"
TIMEOUT_SEC="${TIMEOUT_SEC:-3}"
REAL_DIR="$HOME/Library/Application Support/SideDesk"

if [ ! -x "$APP" ]; then
    echo "FAIL: 未找到 $APP，先跑 ./build.sh"
    exit 1
fi

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sidest-smoke-XXXXXX")"
rm -rf "$TEST_DIR"   # 应用会自己建；这里先留一个不存在的路径

FAILS=0
check() {  # check <说明> <命令...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "ok   $label"
    else
        echo "FAIL $label"
        FAILS=$((FAILS + 1))
    fi
}

# 真实目录快照（前后比对，确认冒烟没往产品目录写东西）
real_snapshot() { ls -lRT "$REAL_DIR" 2>/dev/null | sed 's/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]//g'; }
BEFORE="$(real_snapshot)"

# 后端接口一旦发出就会在 app.log 留一行 [DataVariable]/[Team] 记录
no_backend_request() { ! grep -qE '\[DataVariable\]|\[Team\]' "$1"; }
# 进程名精确匹配（-x）：`pgrep -f SidestMac` 会把命令行里带仓库路径的无关进程也算成残留
no_leftover_process() { ! pgrep -x SidestMac >/dev/null && ! pgrep -f 'remote-debugging-port' >/dev/null; }

START=$(date +%s)
"$APP" --test-mode --test-dir="$TEST_DIR" --test-timeout "$TIMEOUT_SEC" >/dev/null 2>&1
EXIT=$?
ELAPSED=$(( $(date +%s) - START ))
LOG="$TEST_DIR/Logs/app.log"

echo "== 冒烟：--test-mode --test-dir=$TEST_DIR --test-timeout $TIMEOUT_SEC =="
check "干净退出（exit=0，实际 $EXIT）" test "$EXIT" -eq 0
check "自动退出耗时约 ${TIMEOUT_SEC}s（实际 ${ELAPSED}s）" test "$ELAPSED" -ge "$TIMEOUT_SEC" -a "$ELAPSED" -le "$((TIMEOUT_SEC + 6))"
check "隔离目录里有 $LOG" test -f "$LOG"
check "隔离目录里有 sidedesk.db" test -f "$TEST_DIR/sidedesk.db"
check "隔离目录里有 runtime-config.json" test -f "$TEST_DIR/runtime-config.json"
check "启动横幅 mode=test" grep -q "SideDesk starting: .*mode=test" "$LOG"
check "启动耗时行带 test-mode 标记" grep -q "boot done in .*test-mode" "$LOG"
check "记录了自动退出" grep -q "auto shutdown in $TIMEOUT_SEC" "$LOG"
check "未登录时不发后端请求" no_backend_request "$LOG"
check "真实数据目录零写入" test "$(real_snapshot)" = "$BEFORE"
check "无残留进程" no_leftover_process

rm -rf "$TEST_DIR"
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: 全部断言通过"
    exit 0
fi
echo "FAIL: $FAILS 条断言未通过"
exit 1
