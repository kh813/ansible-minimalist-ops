#!/usr/bin/env bash
# ==============================================================================
# ansible-minimalist-ops 実行用ラッパースクリプト
# 
# 主な機能:
# 1. flock による二重起動防止（パッケージマネージャのロック競合防止）
# 2. Python 仮想環境 (.venv) の自動ロード
# 3. 外部死活監視（Healthchecks.io 等）へのデッドマンズスイッチ連携
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 1. 二重起動防止の排他ロック（fd 200）
LOCK_FILE="/tmp/ansible_minimalist_ops.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] エラー: 他のメンテナンス処理が実行中です。重複実行を防止するため終了します。" >&2
    exit 1
fi

# 2. 仮想環境のロード
if [ -n "${VIRTUAL_ENV:-}" ] && [ -f "${VIRTUAL_ENV}/bin/activate" ]; then
    source "${VIRTUAL_ENV}/bin/activate"
elif [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
elif [ -f "${HOME}/.venv/bin/activate" ]; then
    source "${HOME}/.venv/bin/activate"
elif [ -f "${HOME}/ansible-minimalist-ops/.venv/bin/activate" ]; then
    source "${HOME}/ansible-minimalist-ops/.venv/bin/activate"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 警告: .venv が見つかりません。システムの Python 環境で実行します。" >&2
fi

# 3. 環境変数の設定
# 必要に応じて実環境の Webhook URL や死活監視 URL を設定してください。
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SNITCH_URL="${SNITCH_URL:-}"

PLAYBOOK="$1"

if [ -z "$PLAYBOOK" ]; then
    echo "使用法: $0 [playbook_name.yml] [ansible-playbook追加オプション...]"
    echo "例:   $0 apply_updates.yml"
    echo "例:   $0 check_updates.yml --limit linux_web"
    exit 1
fi

# 4. インベントリの自動構文検証（文法ミスを事前に即時検知）
if ! ansible-inventory --list >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 【構文エラー】インベントリ設定 (inventory/hosts.yml) に文法ミスがあります。" >&2
    echo "--> エラー詳細:" >&2
    ansible-inventory --list >&2 || true
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === メンテナンス開始: ${PLAYBOOK} ==="

# 外部監視へ開始シグナル送信
if [ -n "$SNITCH_URL" ]; then
    curl -fsS -m 10 --retry 3 "${SNITCH_URL}/start" >/dev/null 2>&1 || true
fi

# Playbook 実行（引数を受け渡す）
set +e
ansible-playbook "playbooks/${PLAYBOOK}" "${@:2}"
EXIT_CODE=$?
set -e

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === メンテナンス終了 (終了コード: ${EXIT_CODE}) ==="

# 4. 外部監視へ成否ハートビート送信
if [ -n "$SNITCH_URL" ]; then
    if [ ${EXIT_CODE} -eq 0 ]; then
        curl -fsS -m 10 --retry 3 "${SNITCH_URL}" >/dev/null 2>&1 || true
    else
        curl -fsS -m 10 --retry 3 "${SNITCH_URL}/fail" >/dev/null 2>&1 || true
    fi
fi

exit ${EXIT_CODE}
