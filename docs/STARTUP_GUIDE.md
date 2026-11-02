# 初心者のための Ansible スタートアップガイド

> Ansible を触ったことがない一人情シスや新任インフラ担当者が、迷わず安全に運用を始められるための超入門＆実践ガイドです。

---

## 1. 最初に知っておくべき 4つの基本概念

Ansible は、専用のエージェントをサーバーに常駐させることなく、**SSH（Linux）や WinRM（Windows）経由でリモート操作を行う自動化ツール**です。覚えるべき基本用語は以下の4つだけです。

| 用語 | 意味 | 本プロジェクトでの実体 |
| :--- | :--- | :--- |
| **インベントリ (Inventory)** | 管理対象サーバーの一覧と設定が書かれた台帳 | [`inventory/hosts.yml`](../inventory/hosts.yml) |
| **プレイブック (Playbook)** | 「どんな順番で何を実行するか」を書いた手順書 (YAML) | `playbooks/*.yml` |
| **タスク / モジュール** | 「パッケージ更新」「再起動」などの具体的なコマンド部品 | `ansible.builtin.apt`, `ansible.builtin.reboot` 等 |
| **ファクト (Facts)** | 実行時にAnsibleが対象サーバーから自動収集するOS情報（OS名、ディスク空き容量、IPアドレス等） | `ansible_os_family`, `ansible_mounts` 等 |

---

## 2. 初回導入の 3ステップ（これだけで準備完了）

管理される側のサーバーには Git も Ansible も不要です。

```
[あなたの管理サーバー] ──────── SSH接続 ────────▶ [管理対象サーバー (Web/DB)]
  (Ansible本体を実行)                            (公開鍵を1行追加するだけ)
```

### ステップ①：管理サーバー側のセットアップ
管理サーバー（Ubuntu等）で仮想環境を作成し、Ansible を導入します。

```bash
# 必要パッケージの導入
sudo apt update && sudo apt install -y python3-pip python3-venv git curl util-linux

# リポジトリ取得と仮想環境構築
git clone https://github.com/kh813/ansible-minimalist-ops.git ~/ansible-minimalist-ops
cd ~/ansible-minimalist-ops

python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install ansible

# SSH秘密鍵・公開鍵ペアの作成（未作成の場合）
ssh-keygen -t ed25519 -C "ansible-manager@ops" -f ~/.ssh/ansible_manager_key -N ""
```

### ステップ②：管理対象サーバー側の受入（初回1回のみ）
管理したいサーバーにログインし、管理サーバーの公開鍵（`~/.ssh/ansible_manager_key.pub` の中身）を登録し、パスワードなし sudo を付与します。

```bash
# 【対象サーバー上で実行】
sudo useradd -m -s /bin/bash opsadmin
sudo mkdir -p /home/opsadmin/.ssh
echo "ssh-ed25519 AAAAC3...[公開鍵の中身]..." | sudo tee /home/opsadmin/.ssh/authorized_keys
sudo chown -R opsadmin:opsadmin /home/opsadmin/.ssh
sudo chmod 700 /home/opsadmin/.ssh
sudo chmod 600 /home/opsadmin/.ssh/authorized_keys

# パスワードなしsudoの許可
echo "opsadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/opsadmin
sudo chmod 440 /etc/sudoers.d/opsadmin
```

### ステップ③：インベントリ（`inventory/hosts.yml`）への登録
[`inventory/hosts.yml`](../inventory/hosts.yml) に対象ホストの情報を追記します。

```yaml
all:
  children:
    linux_servers:
      children:
        linux_web:
          hosts:
            web01.corp.internal:
              ansible_host: 192.168.10.21        # 実際のIPアドレス
              healthcheck_url: http://192.168.10.21/health
              healthcheck_expected_body: ok       # 応答本文に含まれるべきキーワード
              target_services:
                - nginx                           # 必須常駐サービス
```

---

## 3. 安全に動かすための「お作法」（初心者が知っておくべきコマンド）

いきなり本番実行するのが怖いときは、以下のコマンドで安全確認ができます。

### ① 構文エラーの事前チェック（文法確認）
```bash
# インベントリの書式チェック（ミスがあれば行番号が表示されます）
ansible-inventory --graph

# Playbookの構文チェック
ansible-playbook playbooks/check_updates.yml --syntax-check
```

### ② 疎通テスト（Ping）
管理サーバーから対象ホストへSSH接続とsudoができるか確認します。
```bash
ansible linux_servers -m ping
# 成功すれば "ping": "pong" と緑色で表示されます
```

### ③ 特定の1台だけを対象に実行（`--limit`）
全サーバーではなく、まず検証用の1台だけで試したい場合は `--limit` オプションを付けます。
```bash
./run_ops.sh check_updates.yml --limit web01.corp.internal
./run_ops.sh apply_updates.yml --limit web01.corp.internal
```

---

## 4. よくある初心者のトラブルと解決策

| 現象 | 主な原因 | 解決策 |
| :--- | :--- | :--- |
| **`yaml.scanner.ScannerError`** | YAMLのインデント（半角スペース）が崩れている | タブ文字を使わず、半角スペース2文字でインデントを揃えてください。VS Code等のエディタを使うとミスを防げます。 |
| **`Permission denied (publickey)`** | SSH公開鍵が対象サーバーに正しく登録されていない | 対象サーバーの `/home/opsadmin/.ssh/authorized_keys` の内容と権限（`600`）を確認してください。 |
| **`Missing sudo password`** | パスワードなし sudo の設定が不足している | 対象サーバーの `/etc/sudoers.d/opsadmin` に `opsadmin ALL=(ALL) NOPASSWD:ALL` があるか確認してください。 |
| **`Host is down` / タイムアウト** | ファイアウォール（セキュリティグループ）でポート22が閉じている | 社内LANまたは管理サーバーからのSSH（ポート22）接続を許可してください。 |
