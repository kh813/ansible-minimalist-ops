# ansible-minimalist-ops

> 一人情シスや少人数サーバー管理チームのための、保守負債ゼロを目指す安全なエージェントレス自動メンテナンス基盤テンプレート。

---

## 📖 概要

**`ansible-minimalist-ops`** は、自作スクリプトや独自ツールの保守負債を排除し、**Ansible標準機能（YAML）とシェルスクリプトだけで「監視・通知・夜間アップデート・安全再起動・深層事後検証」を自動化するための運用スターターキット**です。

### 主な特長
* **エージェントレス**: 管理対象サーバーにGitリポジトリや専用エージェントの導入は不要（SSH / WinRM のみ）。
* **二重起動防止**: `flock` による排他制御で、cron重複やパッケージマネージャ（apt/dnf）のロック衝突を完全防止。
* **徹底した多重防御**:
  * **第0防衛線**: 外部ネットワーク・DNS疎通確認（不通時は安全に更新スキップ）。
  * **第1防衛線**: ディスク容量（`/`, `/boot`）、iノード枯渇（使用率90%）、パッケージ管理DB事前破損チェック（`dpkg --audit` / `dnf check`）。
* **無停止保証**: ロードバランサー（LB）からの安全なトラフィックドレイン＆自動復帰。
* **締め出し防止**: パッチ適用後にSSH再接続・sudo特権昇格テストを実施。
* **深層ヘルスチェック**: 単なるHTTP 200だけでなくレスポンス本文のキーワード精査、DBポート待機、リトライ機構（最大2分）。
* **初動の自動化**: 異常中断時はSlackへ「調査用SSHワンライナー」と「単体再実行コマンド」を即時通知。
* **デッドマンズスイッチ**: 管理サーバー自体の無音停止を外部死活監視（Healthchecks.io等）で検知。

---

## 📂 ディレクトリ構成

```text
ansible-minimalist-ops/
├── README.md                      # 本ドキュメント（クイックスタート）
├── ansible_minimalist_ops.md      # ★実践 運用・保守詳細マニュアル（完全版手順書）
├── .gitignore                     # 鍵・シークレット・キャッシュ除外設定
├── ansible.cfg                    # 共通設定（ログ出力、並列数、権限昇格等）
├── run_ops.sh                     # ★cron実行用ラッパースクリプト（flock排他・外監視連携）
├── inventory/
│   └── hosts.yml                  # 対象ホスト一覧・パラメータ設定 (YAML形式)
├── docs/
│   ├── STARTUP_GUIDE.md           # 🔰 初心者向けスタートアップガイド
│   └── ADVANCED_GUIDE.md          # 🚀 熟練ユーザー向け拡張ガイド＆公式リンク集
├── playbooks/
    ├── check_updates.yml          # 【Linux監視】脆弱性スキャン・JSON出力・Slack通知
    ├── apply_updates.yml          # 【Linux更新】事前検査・LBドレイン・更新・検証・緊急発報
    ├── win_check_updates.yml      # 【Windows監視】Windows Update差分スキャン & 通知
    ├── win_apply_updates.yml      # 【Windows更新】Windows Update適用 & 多重再起動復帰
    └── mac_apply_updates.yml      # 【macOS更新】Homebrew・開発CLIツール一括更新
```

---

## 🚀 クイックスタート

### 1. 管理サーバー側の環境構築

```bash
# 必要パッケージの導入 (Ubuntu / Debian)
sudo apt update
sudo apt install -y python3-pip python3-venv git curl util-linux

# 仮想環境の作成とAnsible導入
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install ansible

# SSH鍵の作成（未作成の場合）
ssh-keygen -t ed25519 -C "ansible-manager@ops" -f ~/.ssh/ansible_manager_key -N ""
```

### 2. 管理対象サーバー（Linux）の受入設定（初回のみ）

管理対象ノードで、管理サーバーの公開鍵を受け入れ、パスワードなしsudoを付与します。

```bash
sudo useradd -m -s /bin/bash opsadmin
sudo mkdir -p /home/opsadmin/.ssh
echo "ssh-ed25519 AAAAC3...[公開鍵の中身]..." | sudo tee /home/opsadmin/.ssh/authorized_keys
sudo chown -R opsadmin:opsadmin /home/opsadmin/.ssh
sudo chmod 700 /home/opsadmin/.ssh
sudo chmod 600 /home/opsadmin/.ssh/authorized_keys

# パスワードなしsudo
echo "opsadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/opsadmin
sudo chmod 440 /etc/sudoers.d/opsadmin
```

### 3. インベントリの編集

`inventory/hosts.yml` を編集し、対象サーバーのIPやヘルスチェック情報を入力します（YAML形式なのでクォートミスなく直感的に書けます）。

```yaml
all:
  children:
    linux_servers:
      children:
        linux_web:
          hosts:
            web01.corp.internal:
              ansible_host: 192.168.10.21
              drain_healthcheck_file: /var/www/html/healthz
              healthcheck_url: http://192.168.10.21/health
              healthcheck_expected_body: ok
              target_services:
                - nginx

        linux_db:
          hosts:
            db01.corp.internal:
              ansible_host: 192.168.10.31
              db_check_port: 5432
              target_services:
                - postgresql
```

### 4. 手動実行テスト

```bash
# 監視（脆弱性スキャン）テスト
./run_ops.sh check_updates.yml

# パッチ適用・ヘルスチェックテスト（単体ホスト）
./run_ops.sh apply_updates.yml --limit web01.corp.internal
```

### 5. 定期スケジュールの設定（cron）

管理サーバー側で `crontab -e` を設定します。

```cron
# 毎朝9時・15時に脆弱性スキャン
0 9,15 * * * /home/opsadmin/ansible-minimalist-ops/run_ops.sh check_updates.yml >> /var/log/ansible_check.log 2>&1

# 毎週日曜 深夜AM3時に自動パッチ適用・再起動・検証
0 3 * * 0 /home/opsadmin/ansible-minimalist-ops/run_ops.sh apply_updates.yml >> /var/log/ansible_apply.log 2>&1
```

---

## 🧪 ローカル統合テスト（Docker）

実機を用意することなく、Docker上で本物の `systemd` を稼働させたターゲットノードを用いて、本手順通りの動作を1コマンドで全自動検証できます。

```bash
./tests/run_tests.sh
```

**検証される内容:**
* SSH公開鍵認証 & sudo特権昇格
* `check_updates.yml` によるスキャンと監査JSON出力
* `apply_updates.yml` による事前健全性検査（容量/inode/パッケージDB）
* LBトラフィックドレイン（ヘルスチェック一時退避）
* 非対話OSアップデート適用
* SSHロックアウト防止テスト
* Nginx 稼働 & Web深層ヘルスチェック（HTTP 200 + キーワード検証）
* LBヘルスチェックファイルの復元


---

## 📚 ドキュメント体系

目的や習熟度に合わせて以下のドキュメントを参照してください。

* 🔰 **[初心者向けスタートアップガイド](docs/STARTUP_GUIDE.md)**:
  Ansibleに初めて触れる新任担当者向け。4つの基本用語、初回の3ステップ、構文チェックやPing疎通テスト、よくあるミス集。
* 📖 **[実践 運用・保守詳細マニュアル（本編）](ansible_minimalist_ops.md)**:
  アーキテクチャ詳細、多重防衛仕様、実機パラメータ微調整ガイド、トラブルシューティングを網羅した完全版仕様書。
* 🚀 **[熟練ユーザー向け拡張ガイド ＆ リンク集](docs/ADVANCED_GUIDE.md)**:
  Ansible Vaultによるシークレット暗号化、AWS/Azure動的インベントリ、AWX/AAP連携、公式リファレンスリンク集。
