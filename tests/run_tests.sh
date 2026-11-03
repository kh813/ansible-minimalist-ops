#!/usr/bin/env bash
# ==============================================================================
# ansible-minimalist-ops 自動統合テストスクリプト
# 
# 目的:
# Docker コンテナ（systemd 稼働の Ubuntu ノード）を用いて、
# 手順書（マニュアル）通りの設定・Playbook 実行が問題なく成功することを検証します。
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KEYS_DIR="${SCRIPT_DIR}/keys"

echo "================================================================="
echo "  ansible-minimalist-ops Docker 統合テストを開始します"
echo "================================================================="

# 1. テスト用 SSH 鍵ペアの生成（手順書 3.2 の再現）
mkdir -p "${KEYS_DIR}"
if [ ! -f "${KEYS_DIR}/ansible_manager_key" ]; then
    echo "[1/5] テスト用 SSH 鍵ペアを作成中..."
    ssh-keygen -t ed25519 -C "test-manager@ops" -f "${KEYS_DIR}/ansible_manager_key" -N ""
    # セキュリティ強化: from="IP" による接続元固定（手順書 2.3 の再現）
    echo 'from="172.28.0.10" '$(cat "${KEYS_DIR}/ansible_manager_key.pub") > "${KEYS_DIR}/authorized_keys"
    chmod 600 "${KEYS_DIR}/ansible_manager_key"
    chmod 600 "${KEYS_DIR}/authorized_keys"
else
    echo "[1/5] 既存のテスト用 SSH 鍵ペアを使用します。"
fi

# クリーンアップ用トラップ
cleanup() {
    echo ""
    echo "コンテナ環境をクリーンアップ中..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
    echo "クリーンアップ完了。"
}

if [ "${1:-}" == "--cleanup-only" ]; then
    cleanup
    exit 0
fi

trap cleanup EXIT

# 2. Docker コンテナ群のビルドと起動
echo "[2/5] テスト用コンテナ環境を起動中 (web01: Target, manager: Ansible Controller)..."
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build

# 3. Target (web01) の起動・SSH 待受待機
echo "[3/5] Target ノード (172.28.0.21) の起動・SSH 待受を待機中..."
for i in {1..30}; do
    if docker exec ansible-test-web01 systemctl is-system-running >/dev/null 2>&1; then
        STATUS=$(docker exec ansible-test-web01 systemctl is-system-running 2>&1 || true)
        if [ "$STATUS" == "running" ] || [ "$STATUS" == "degraded" ]; then
            echo "       Target の systemd が稼働状態になりました ($STATUS)。"
            break
        fi
    fi
    sleep 1
    if [ $i -eq 30 ]; then
        echo "エラー: Target ノードの起動待機がタイムアウトしました。" >&2
        exit 1
    fi
done

# 手順書 4.1 の受入準備を再現（公開鍵の配置とパーミッション設定）
docker exec ansible-test-web01 mkdir -p /home/opsadmin/.ssh
docker cp "${KEYS_DIR}/authorized_keys" ansible-test-web01:/home/opsadmin/.ssh/authorized_keys
docker exec ansible-test-web01 chown -R opsadmin:opsadmin /home/opsadmin/.ssh
docker exec ansible-test-web01 chmod 700 /home/opsadmin/.ssh
docker exec ansible-test-web01 chmod 600 /home/opsadmin/.ssh/authorized_keys

# 4. 【テスト 1】監視 Playbook (check_updates.yml) の実行検証
echo ""
echo "================================================================="
echo "  [テスト 1] check_updates.yml (脆弱性スキャン・状態JSON出力)"
echo "================================================================="
docker exec -u opsadmin ansible-test-manager bash -c '
    cd /home/opsadmin/ansible-minimalist-ops
    ./run_ops.sh check_updates.yml
'

echo "--> 検証: 監査 JSON レポート (/tmp/audit_web01.corp.internal.json) の出力を確認..."
docker exec -u opsadmin ansible-test-manager bash -c '
    test -f /tmp/audit_web01.corp.internal.json && cat /tmp/audit_web01.corp.internal.json
'
echo ""
echo "✅ [テスト 1 成功] 監視 Playbook が正常に動作し、監査レポートが出力されました。"

# 5. 【テスト 2】更新＆事後検証 Playbook (apply_updates.yml) の実行検証
echo ""
echo "================================================================="
echo "  [テスト 2] apply_updates.yml (事前検査・LBドレイン・更新・深層検証)"
echo "================================================================="
docker exec -u opsadmin ansible-test-manager bash -c '
    cd /home/opsadmin/ansible-minimalist-ops
    ./run_ops.sh apply_updates.yml
'

echo "--> 検証: LB ヘルスチェックファイル (/var/www/html/healthz) が正常に復元されているか確認..."
docker exec ansible-test-web01 bash -c '
    test -f /var/www/html/healthz && echo "healthz file exists: OK"
'

echo "--> 検証: Nginx サービスが正常に稼働しているか確認..."
docker exec ansible-test-web01 systemctl is-active nginx

echo ""
echo "================================================================="
echo "  🎉 全テスト合格！"
echo "  テンプレートと手順書通りに設定すれば、問題なく目的が達成できる"
echo "  ことが実機コンテナ環境で確認されました。"
echo "================================================================="
