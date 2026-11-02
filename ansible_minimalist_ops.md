# ansible-minimalist-ops 実践 運用・保守マニュアル

〜 独自ツールの保守負債をゼロにし、既存サーバー・端末の監視・パッチ適用・再起動検証を自動化する 〜

## 1. プロジェクト概要とコンセプト

**`ansible-minimalist-ops`** は、Webアプリケーションの複雑な自動デプロイを行うためのツールではありません。

**「すでに稼働・セットアップされているマシン群」** を対象に、エージェントレス（SSH/WinRM）で安全なメンテナンスサイクル（監視・通知・夜間アップデート・再起動・事後検証）をミニマルに回すための運用基盤です。

### 1.1 なぜ `ansible-minimalist-ops`（標準構成）なのか？

社員数名や業務委託メンバーで構成される少人数体制では、自作スクリプトや独自管理ツールの保守が深刻な負債となります。

* **プロトコル・仕様変更の追従コストゼロ**: OSのメジャー更新、OpenSSH/WinRMの仕様変更、暗号化アルゴリズム刷新のたびに自作ツールを改修する手間を排除します。
* **コード・ノウハウのブラックボックス化を防止**: YAMLによる宣言的記法を採用し、後から参画したメンバーでも容易に処理フローを把握・引き継ぎ可能にします。
* **管理対象ノードを汚さない（エージェントレス）**: 各ノードにGitリポジトリや専用エージェントを配置・同期させる必要がなく、管理サーバー1台で一元管理できます。
* **再起動待機オーケストレーションの標準化**: 自作スクリプトで最も破綻しやすい「再起動指示 → SSH切断 → 復帰ポーリング待機 → 常駐プロセス安定待ち → ヘルスチェック」の一連の流れが、Ansible標準の `ansible.builtin.reboot` で堅牢に完結します。

### 1.2 運用サイクルと導入ロードマップ

```
[ansible-minimalist-ops 管理サーバー]
   │
   ├─ 1. 定期監視 (cron: 日中帯・毎時〜日次)
   │     対象ホスト群へ SSH/WinRM 疎通 ＆ 未適用の重要セキュリティ更新数をスキャン
   │     ├─ 状態JSON出力 (/tmp/audit_*.json ──▶ 簡易Web画面/ダッシュボード連携)
   │     └─ 重要な更新を検知した場合 ──▶ [Slack / Teams / Webhook] へ要対応アラート
   │
   └─ 2. 自動パッチ適用・再起動・事後検証 (cron: 日時・夜間メンテ枠)
         ├─ 排他ロック制御 (flock による二重起動・ロック競合の完全防止)
         ├─ 1台ずつ順次処理 (serial: 1 でサービス全滅を防止)
         │
         ├─ 【第0防衛線】外部ネットワーク・リポジトリ疎通確認 (不通時は安全に更新スキップ)
         ├─ 【第1防衛線】ハードウェア＆OS健全性事前検査
         │     ├─ ディスク容量（/ と /boot）
         │     ├─ iノード（inode）枯渇チェック（使用率90%未満）
         │     └─ パッケージ管理DB事前健全性チェック (dpkg/dnfの破損・未完了トランザクション検知)
         │
         ├─ 【無停止保証】トラフィックの安全なドレイン (LB/Proxyから切り離し・接続完了待ち)
         ├─ OSアップデート適用 (非対話モードでプロンプト停止を完全抑止)
         ├─ 【特権検証】管理者締め出し(SSHロックアウト)防止テスト (SSH再接続＆sudo昇格確認)
         │
         ├─ 再起動フラグ検知 ──▶ 自動再起動 ──▶ 通信復旧を自動ポーリング待機
         ├─ 【深層事後検証】ヘルスチェック (OS差異吸収・必須サービス・DBポート・HTTPレスポンス精査)
         ├─ 【トラフィック復帰】LBへの再組み込み (ドレイン解除)
         │
         ├─ 成功/失敗レポート通知 ──▶ [Slack / Teams] (失敗時は即時調査ワンライナー付き)
         └─ 【デッドマンズスイッチ】外部死活監視へのハートビート送信 (管理基盤自体の無音死を検知)
```

段階的なサポート順序：
1. **フェーズ1（最優先・即効性大）**: Linux サーバー（Ubuntu / Debian / RHEL系）
2. **フェーズ2（次期展開）**: Windows サーバー / クライアント端末（OpenSSH または WinRM）
3. **フェーズ3（将来拡張）**: macOS 端末（Homebrew・CLI開発環境の自動更新 / OS更新はMDM推奨）

---

## 2. 管理サーバーのアーキテクチャとサイジング

### 2.1 独立した管理専用VMの原則

管理サーバーには、管理対象ホストへの特権昇格キー（sudo権限）やSSH秘密鍵が集約されます。セキュリティ境界を担保し、業務サーバーへのリソース影響を避けるため、**既存の業務サーバーと同居させず、必ず独立した管理専用VM（または踏み台コンテナ）** を用意します。

```
[ansible-minimalist-ops 管理サーバー (Linux VM)]
   │
   ├─ Python 仮想環境 (.venv)
   ├─ 必要コレクション (ansible.windows / community.general 等)
   ├─ インベントリ（hosts.ini）
   ├─ Playbook 群（監視・適用 YAML）
   └─ cron スケジューラー (flock 排他制御付きラッパー)
         │
         ├─ [フェーズ1] SSH (Linux) ───────────────▶ [社内Linux サーバー群]
         ├─ [フェーズ2] OpenSSH / WinRM (Windows) ─▶ [社内Windows PC / サーバー]
         ├─ [フェーズ3] SSH (macOS) ───────────────▶ [社内MacBook / Mac端末]
         ├─ Webhook (Slack / Teams) ──────────────▶ [管理者・チーム通知]
         └─ Dead Man's Snitch (Healthchecks.io) ──▶ [外部死活監視ハートビート]
```

### 2.2 管理サーバーのサイジング目安

Ansibleはデーモン常駐型ではなく、コマンド実行時のみPythonプロセスが起動するため非常に軽量です。

| 項目 | 最小構成（〜10台程度） | 推奨構成（10〜100台規模） | 備考 |
| :--- | :--- | :--- | :--- |
| **CPU** | 1 vCPU | **2 〜 4 vCPU** | 並列処理数（`forks`）を増やす際にCPUコア数が影響 |
| **RAM** | 1 GB | **2 〜 4 GB** | Fact収集やログ処理時のメモリ安定性 |
| **ストレージ** | 20 GB (SSD) | **40 〜 60 GB (SSD)** | OS、Ansible、実行ログ、ステータスJSONの出力先 |
| **推奨OS** | Ubuntu Server 24.04 LTS / Rocky Linux 9 | Ubuntu Server 24.04 LTS / Rocky Linux 9 | 長期サポート(LTS)版を採用 |
| **ネットワーク**| 100 Mbps (社内LAN) | 1 Gbps (社内LAN) | パッケージ取得・配信の並列帯域 |

---

## 3. 初期セットアップと環境構成

### 3.1 管理元マシンへのリポジトリ展開と環境構築

管理サーバー側でのみリポジトリを展開し、Python仮想環境（venv）を構築します。管理される側のVMや端末にGitリポジトリを落とす必要はありません。

```bash
# 必要パッケージの導入 (Ubuntu / Debian)
sudo apt update
sudo apt install -y python3-pip python3-venv git curl util-linux

# リポジトリのクローンとディレクトリ移動
git clone https://github.com/your-org/ansible-minimalist-ops.git ~/ansible-minimalist-ops
cd ~/ansible-minimalist-ops

# venvの作成と有効化
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install ansible

# 【フェーズ2・3用】必要に応じて追加
pip install pywinrm
ansible-galaxy collection install ansible.windows chocolatey.chocolatey community.general
```

### 3.2 SSH 鍵ペアの作成

```bash
ssh-keygen -t ed25519 -C "ansible-manager@ops" -f ~/.ssh/ansible_manager_key -N ""
```

### 3.3 プロジェクト構成

```
ansible-minimalist-ops/
├── .venv/                         # Python仮想環境
├── ansible.cfg                    # 共通設定（ログ出力、並列数等）
├── run_ops.sh                     # cron実行用ラッパースクリプト（flock・外監視連携）
├── inventory/
│   └── hosts.ini                  # 対象ホスト一覧（グループ・固有変数定義）
├── playbooks/
│   │  # --- [フェーズ1: Linux] ---
│   ├── check_updates.yml          # 【監視】セキュリティ更新チェック & 通知
│   ├── apply_updates.yml          # 【更新】事前検査・LBドレイン・更新・検証
│   │
│   │  # --- [フェーズ2: Windows] ---
│   ├── win_check_updates.yml      # 【監視】Windows Update差分スキャン & 通知
│   ├── win_apply_updates.yml      # 【更新】Windows Update適用 & 多重再起動復帰
│   │
│   │  # --- [フェーズ3: Mac] ---
│   └── mac_apply_updates.yml      # 【更新】Homebrew・開発ツール一括更新
└── tests/                         # ★Docker 統合テスト環境
    ├── Dockerfile.target          # ターゲット検証用 Ubuntu ノード (systemd)
    ├── Dockerfile.manager         # Ansible 実行元検証用 Controller ノード
    ├── docker-compose.yml         # テスト環境オーケストレーション
    └── run_tests.sh               # ワンコマンド全自動テストスクリプト
```

### 3.4 共通設定（`ansible.cfg`）

```ini
[defaults]
inventory = inventory/hosts.ini
remote_user = opsadmin
private_key_file = ~/.ssh/ansible_manager_key
host_key_checking = False
retry_files_enabled = False
stdout_callback = default
inject_facts_as_vars = True
forks = 10

[callback_default]
result_format = yaml

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
```

### 3.5 インベントリファイル（`inventory/hosts.ini`）

WebサーバーとDBサーバーの依存関係、ロードバランサー切り離し用のヘルスチェックファイル、および深層ヘルスチェック用の変数を定義します。

```ini
[all:vars]
ansible_user=opsadmin
ansible_ssh_private_key_file=~/.ssh/ansible_manager_key
ansible_python_interpreter=/usr/bin/python3

# =========================================================
# フェーズ1: 稼働中 Linux サーバー（最優先）
# =========================================================
# Web / AP サーバー
# - drain_healthcheck_file: LBが監視しているヘルスチェックファイル（一時退避でLBから安全にドレイン）
# - healthcheck_url: 検証用エンドポイント
# - healthcheck_expected_body: 期待するレスポンス本文のキーワード
[linux_web]
web01.corp.internal ansible_host=192.168.10.21 drain_healthcheck_file=/var/www/html/healthz healthcheck_url=http://192.168.10.21/health healthcheck_expected_body='{"status":"ok"}' target_services='["nginx"]'
web02.corp.internal ansible_host=192.168.10.22 drain_healthcheck_file=/var/www/html/healthz healthcheck_url=http://192.168.10.22/health healthcheck_expected_body='{"status":"ok"}' target_services='["nginx"]'

# DB サーバー（Webの依存先）
# - db_check_port: 再起動復帰後に疎通確認する待受ポート
[linux_db]
db01.corp.internal  ansible_host=192.168.10.31 db_check_port=5432 target_services='["postgresql"]'

[linux_servers:children]
linux_web
linux_db

# =========================================================
# フェーズ2: Windows（次期展開・OpenSSH または WinRM）
# =========================================================
[windows_servers]
# 【推奨】Windows標準のOpenSSHサーバーを利用する場合（Linuxと鍵認証を共通化可能）
# win01.corp.internal ansible_host=192.168.20.101 ansible_user=opsadmin ansible_connection=ssh ansible_shell_type=powershell

# 【従来方式】WinRMを利用する場合
# win02.corp.internal ansible_host=192.168.20.102 ansible_user=Administrator ansible_connection=winrm ansible_port=5986 ansible_winrm_server_cert_validation=ignore

# =========================================================
# フェーズ3: macOS 端末（将来拡張・開発環境更新）
# =========================================================
[mac_clients]
# mac01.corp.internal ansible_host=192.168.20.51 ansible_user=admin_mac ansible_connection=ssh
```

### 3.6 実機環境への導入・環境固有パラメータの微調整ガイド

本仕様書は極めて堅牢に設計されていますが、実機環境へ投入する際は**自社のシステム構成・インフラ仕様に合わせて以下のパラメータを必ず確認・微調整**してください。

| パラメータ名 | 定義場所 | 設定内容と微調整のポイント |
| :--- | :--- | :--- |
| **`drain_healthcheck_file`** | `hosts.ini` | **LBドレイン用ファイルパス**: AWS ALB、Cloudflare、Nginx、HAProxy等のロードバランサーが監視しているヘルスチェック用静的ファイル（例: `/var/www/html/healthz`）を指定します。<br>※ファイルを一時退避（`.disabled`）することでLBに自動でUnhealthyと認識させ、無停止で切り離します。 |
| **`drain_wait_seconds`** | `apply_updates.yml` | **コネクション抜け待ち時間**: LBから切り離した後、処理中の既存リクエストが完了するのを待つ秒数（デフォルト25秒）。ロングポーリングや決済処理など長時間の接続があるアプリは `45` 〜 `60` 秒に拡大を推奨。 |
| **`healthcheck_expected_body`** | `hosts.ini` | **深層ヘルスチェック期待値**: 単なるHTTP 200だけでなく、アプリが内部（DB接続等）まで正常稼働しているかを確認する文字列（例: `{"status":"ok"}` や `healthy`）。 |
| **`target_services`** | `hosts.ini` | **ホスト固有必須サービス一覧**: 各サーバーで再起動後に必ず稼働していなければならないデーモン（例: `nginx`, `postgresql`, `docker`, `redis` 等）をJSON配列形式で定義。 |
| **`db_check_port`** | `hosts.ini` | **DB待受ポート**: DBサーバーの再起動復帰時に外部からポート疎通を確認するポート番号（PostgreSQLなら `5432`、MySQLなら `3306` 等）。 |
| **`retries` / `delay`** | `apply_updates.yml` | **Web復帰リトライ設定**: Webサービスの起動所要時間（Java/Tomcat、Python、Node、Docker等のアプリ起動時間）に合わせて回数と間隔を調整（デフォルト: 10秒おき×12回＝最大2分間）。 |

---

## 4. 【フェーズ1：最優先】Linux サーバーの運用自動化

### 4.1 管理対象側の受入準備（Linux初回のみ）

管理対象ノード側にはGitもAnsible本体も不要です。管理サーバーの公開鍵を受け入れ、パスワードなしsudoを付与するだけで準備が整います。

```bash
# 【管理対象Linux側で1回だけ実行】
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

### 4.2 監視Playbook（`playbooks/check_updates.yml`）

重要更新の有無を日中に検知し、Slack等へ発報すると同時に、可視化用のJSONレポートをローカル保存します。

```yaml
---
- name: サーバーの更新状態スキャンとWebhook通知
  hosts: linux_servers
  gather_facts: yes
  vars:
    slack_webhook_url: "{{ lookup('env', 'SLACK_WEBHOOK_URL') | default('', true) }}"

  tasks:
    # 1. Debian / Ubuntu の更新件数チェック
    - name: 【Debian/Ubuntu】パッケージリスト更新
      when: ansible_os_family == "Debian"
      ansible.builtin.apt:
        update_cache: yes
        cache_valid_time: 1800

    - name: 【Ubuntu】apt-check コマンドの確認
      when: ansible_distribution == "Ubuntu"
      ansible.builtin.stat:
        path: /usr/lib/update-notifier/apt-check
      register: apt_check_bin

    - name: 【Ubuntu】更新件数の取得
      when: 
        - ansible_distribution == "Ubuntu"
        - apt_check_bin.stat.exists
      ansible.builtin.command: /usr/lib/update-notifier/apt-check
      register: apt_check_raw
      changed_when: false

    - name: 【Ubuntu】件数のパース
      when: 
        - ansible_distribution == "Ubuntu"
        - apt_check_bin.stat.exists
      ansible.builtin.set_fact:
        normal_updates: "{{ apt_check_raw.stderr.split(';')[0] | int }}"
        security_updates: "{{ apt_check_raw.stderr.split(';')[1] | int }}"

    - name: 【Debian】セキュリティ更新件数の算出
      when: ansible_distribution == "Debian"
      ansible.builtin.shell: |
        apt-get -s dist-upgrade | grep "^Inst" | grep -iE "security|debian-security" | wc -l
      register: debian_sec_raw
      changed_when: false

    - name: 【Debian】件数のセット
      when: ansible_distribution == "Debian"
      ansible.builtin.set_fact:
        normal_updates: 0
        security_updates: "{{ debian_sec_raw.stdout | int }}"

    # 2. RHEL / Rocky / AlmaLinux の更新件数チェック
    - name: 【RHEL系】dnf セキュリティ更新チェック
      when: ansible_os_family == "RedHat"
      ansible.builtin.command: dnf updateinfo list --security
      register: rhel_sec_raw
      failed_when: false
      changed_when: false

    - name: 【RHEL系】件数のセット
      when: ansible_os_family == "RedHat"
      ansible.builtin.set_fact:
        normal_updates: 0
        security_updates: "{{ (rhel_sec_raw.stdout_lines | length - 1) if (rhel_sec_raw.stdout_lines | length > 1) else 0 }}"

    # 3. 状態レポート出力（ダッシュボード・可視化連携用）
    - name: 各ホストの監査レポートを出力
      ansible.builtin.copy:
        content: |
          {
            "host": "{{ inventory_hostname }}",
            "ip": "{{ ansible_host }}",
            "os": "{{ ansible_distribution }} {{ ansible_distribution_version }}",
            "security_updates": {{ security_updates | default(0) }},
            "last_checked": "{{ ansible_date_time.iso8601 }}"
          }
        dest: "/tmp/audit_{{ inventory_hostname }}.json"
      delegate_to: localhost
      become: no

    # 4. Webhook 通知（セキュリティ更新が1件以上ある場合のみ発報）
    - name: 重要アップデートのアラート通知 (Slack)
      when:
        - security_updates | default(0) | int > 0
        - slack_webhook_url != ""
      ansible.builtin.uri:
        url: "{{ slack_webhook_url }}"
        method: POST
        body_format: json
        body:
          text: |
            :warning: *【要更新】セキュリティアップデート検知*
            ・対象ホスト: `{{ inventory_hostname }}` ({{ ansible_host }})
            ・未適用セキュリティ更新: *{{ security_updates }}* 件
            ・OS: {{ ansible_distribution }} {{ ansible_distribution_version }}
            夜間の自動更新スケジュールで適用されるか、手動パッチ実行を検討してください。
        status_code: 200
      delegate_to: localhost
      become: no
```

### 4.3 適用＆ヘルスチェックPlaybook（`playbooks/apply_updates.yml`）

`serial: 1` で1台ずつ順次処理します。
**外部疎通確認（第0防衛線）**、**容量・inode・パッケージDB検査（第1防衛線）**、**LBドレイン（無停止保証）**、**SSHロックアウト防止テスト**、**深層事後検証**、および**ワンライナー付きエラー発報** を完備した完全防御構成です。

```yaml
---
- name: サーバーアップデート・安全再起動・深層事後検証
  hosts: linux_servers
  serial: 1            # 1台ずつ順番に処理（サービス全滅を防止）
  gather_facts: yes
  become: yes
  vars:
    slack_webhook_url: "{{ lookup('env', 'SLACK_WEBHOOK_URL') | default('', true) }}"
    min_root_free_mb: 1024        # / に最低限必要な空き容量 (MB)
    min_boot_free_mb: 200         # /boot に最低限必要な空き容量 (MB)
    max_inode_used_percent: 90    # 許容する最大iノード使用率 (%)
    drain_wait_seconds: 25        # LB切り離し後のコネクション抜け待ち時間 (秒)

  tasks:
    - name: 安全メンテナンス処理メインブロック
      block:
        # =========================================================
        # 【第0防衛線】外部ネットワーク・DNS疎通チェック
        # =========================================================
        - name: 外部リポジトリおよびDNSへの疎通確認
          ansible.builtin.uri:
            url: "https://cloudflare.com"
            status_code: [200, 301, 302]
            timeout: 5
          register: net_check
          ignore_errors: yes

        - name: ネットワーク不通時の安全スキップ
          when: net_check.failed | default(false)
          ansible.builtin.fail:
            msg: "外部ネットワーク・DNSの名前解決が失敗しました。不完全なアップデートを防ぐため、本ホストの更新を安全に中断します。"

        # =========================================================
        # 【第1防衛線】ハードウェア・iノード・パッケージDB健全性検査
        # =========================================================
        - name: ルートパーティション(/)の空き容量確認
          ansible.builtin.assert:
            that:
              - item.size_available > (min_root_free_mb * 1024 * 1024)
            fail_msg: "【中止】/ の空き容量が不足しています（最低 {{ min_root_free_mb }}MB 必要）。"
          loop: "{{ ansible_mounts }}"
          when: item.mount == '/'

        - name: /boot パーティションの空き容量確認（独立マウント時）
          ansible.builtin.assert:
            that:
              - item.size_available > (min_boot_free_mb * 1024 * 1024)
            fail_msg: "【中止】/boot の空き容量が不足しています（最低 {{ min_boot_free_mb }}MB 必要）。"
          loop: "{{ ansible_mounts }}"
          when: item.mount == '/boot'

        - name: 各マウントポイントのiノード（inode）使用率確認
          ansible.builtin.assert:
            that:
              - "(item.inode_used / item.inode_total * 100) < max_inode_used_percent"
            fail_msg: "【中止】マウント {{ item.mount }} のiノードが枯渇寸前です（{{ max_inode_used_percent }}% 超過）。"
          loop: "{{ ansible_mounts }}"
          when: item.inode_total is defined and item.inode_total > 0

        - name: 【Debian/Ubuntu】パッケージ管理DBの事前健全性チェック (dpkg --audit)
          when: ansible_os_family == "Debian"
          ansible.builtin.command: dpkg --audit
          register: dpkg_audit
          changed_when: false
          failed_when: dpkg_audit.stdout != ""

        - name: 【RHEL系】パッケージ管理DBの事前健全性チェック (dnf check)
          when: ansible_os_family == "RedHat"
          ansible.builtin.command: dnf check
          register: dnf_check
          changed_when: false
          failed_when: dnf_check.rc != 0

        # =========================================================
        # 【無停止保証】トラフィックの安全なドレイン（LB切り離し）
        # =========================================================
        - name: LBヘルスチェックファイルの存在確認
          when: drain_healthcheck_file is defined
          ansible.builtin.stat:
            path: "{{ drain_healthcheck_file }}"
          register: hc_file_stat

        - name: LBから安全に切り離し（ヘルスチェックファイルを一時退避）
          when: 
            - drain_healthcheck_file is defined
            - hc_file_stat.stat.exists
          ansible.builtin.command: "mv {{ drain_healthcheck_file }} {{ drain_healthcheck_file }}.disabled"

        - name: 既存コネクションが抜けるまで待機（ドレイン待機）
          when: 
            - drain_healthcheck_file is defined
            - hc_file_stat.stat.exists
          ansible.builtin.pause:
            seconds: "{{ drain_wait_seconds }}"

        # =========================================================
        # パッケージ更新（非対話モード・プロンプト停止の防止）
        # =========================================================
        - name: 【Debian/Ubuntu】OSアップデートの適用 (非対話モード)
          when: ansible_os_family == "Debian"
          ansible.builtin.apt:
            update_cache: yes
            upgrade: dist
            autoremove: yes
            dpkg_options: 'force-confdef,force-confold'
          environment:
            DEBIAN_FRONTEND: noninteractive

        - name: 【RHEL系】dnf アップデートの適用
          when: ansible_os_family == "RedHat"
          ansible.builtin.dnf:
            name: "*"
            state: latest

        # =========================================================
        # 【特権検証】管理者締め出し（SSHロックアウト）防止テスト
        # =========================================================
        - name: SSH接続セッションのリフレッシュ
          ansible.builtin.meta: reset_connection

        - name: パッチ適用後のsudo特権昇格テスト
          ansible.builtin.command: whoami
          register: sudo_test
          changed_when: false
          failed_when: sudo_test.stdout != "root"

        # =========================================================
        # 再起動が必要かの判定と実行
        # =========================================================
        - name: 【Debian/Ubuntu】再起動要求フラグの確認
          when: ansible_os_family == "Debian"
          ansible.builtin.stat:
            path: /var/run/reboot-required
          register: deb_reboot_needed

        - name: 【RHEL系】再起動判定 (needs-restarting)
          when: ansible_os_family == "RedHat"
          ansible.builtin.command: needs-restarting -r
          register: rhel_reboot_needed
          failed_when: false
          changed_when: false

        - name: 再起動フラグの統合
          ansible.builtin.set_fact:
            needs_reboot: >-
              {{
                (deb_reboot_needed.stat.exists if ansible_os_family == 'Debian' else false) or
                (rhel_reboot_needed.rc == 1 if ansible_os_family == 'RedHat' else false)
              }}

        - name: サーバーの再起動とSSH疎通再開待機
          when: needs_reboot | bool
          ansible.builtin.reboot:
            msg: "ansible-minimalist-ops 定期メンテナンスによる再起動"
            connect_timeout: 15
            reboot_timeout: 600       # 最大10分待機
            post_reboot_delay: 20     # 常駐プロセス安定まで20秒待機
            test_command: whoami      # ログイン確認コマンド

        # =========================================================
        # 【深層事後検証】ヘルスチェック（OS差異吸収・DB・HTTP本文検証）
        # =========================================================
        - name: 【ヘルスチェック】基本SSHデーモンが稼働しているか
          ansible.builtin.systemd:
            name: "{{ 'ssh' if ansible_os_family == 'Debian' else 'sshd' }}"
            state: started

        - name: 【ヘルスチェック】ホスト固有の必須サービスが稼働しているか
          ansible.builtin.systemd:
            name: "{{ item }}"
            state: started
          loop: "{{ target_services | default([]) }}"

        - name: 【ヘルスチェック】DB待受ポートの疎通確認
          when: db_check_port is defined
          ansible.builtin.wait_for:
            host: "{{ ansible_host }}"
            port: "{{ db_check_port }}"
            state: started
            timeout: 30
          delegate_to: localhost
          become: no

        - name: 【ヘルスチェック】Webサービスが正常応答・本文キーワードを返しているか
          when: healthcheck_url is defined
          ansible.builtin.uri:
            url: "{{ healthcheck_url }}"
            status_code: 200
            timeout: 10
            return_content: yes
          register: web_check
          until: >
            web_check.status == 200 and
            (healthcheck_expected_body is not defined or (healthcheck_expected_body in web_check.content))
          retries: 12                # 10秒おきに最大12回（2分間）リトライ
          delay: 10
          delegate_to: localhost
          become: no

        # =========================================================
        # 【トラフィック復帰】LBへの再組み込み（ドレイン解除）
        # =========================================================
        - name: LBヘルスチェックファイルの復元（トラフィック再開）
          when: 
            - drain_healthcheck_file is defined
            - hc_file_stat.stat.exists
          ansible.builtin.command: "mv {{ drain_healthcheck_file }}.disabled {{ drain_healthcheck_file }}"

        # =========================================================
        # 正常完了通知
        # =========================================================
        - name: 更新完了通知 (Slack)
          when: slack_webhook_url != ""
          ansible.builtin.uri:
            url: "{{ slack_webhook_url }}"
            method: POST
            body_format: json
            body:
              text: |
                :white_check_mark: *【成功】ホストメンテナンス完了*
                ・対象ホスト: `{{ inventory_hostname }}` ({{ ansible_host }})
                ・再起動実施: {{ 'あり' if (needs_reboot | bool) else 'なし (再起動不要)' }}
                ・ヘルスチェック: 全テスト合格（LBトラフィック復帰完了）
            status_code: 200
          delegate_to: localhost
          become: no

      # =========================================================
      # 【異常終了ハンドリング】ワンライナー付きエラー発報
      # =========================================================
      rescue:
        - name: 退避したLBヘルスチェックファイルの緊急復元試行
          when: drain_healthcheck_file is defined
          ansible.builtin.shell: |
            if [ -f "{{ drain_healthcheck_file }}.disabled" ]; then
                mv "{{ drain_healthcheck_file }}.disabled" "{{ drain_healthcheck_file }}"
            fi
          ignore_errors: yes

        - name: メンテナンス異常終了のアラート通知 (Slack)
          when: slack_webhook_url != ""
          ansible.builtin.uri:
            url: "{{ slack_webhook_url }}"
            method: POST
            body_format: json
            body:
              text: |
                :rotating_light: *【緊急警報】ホストメンテナンス失敗・安全中断*
                ・対象ホスト: `{{ inventory_hostname }}` ({{ ansible_host }})
                ・エラー詳細: `{{ ansible_failed_result.msg | default(ansible_failed_task.name | default('不明なタスクで失敗')) }}`
                
                :tools: *即時調査用ワンライナー:*
                `ssh {{ ansible_user }}@{{ ansible_host }} "journalctl -xe --no-pager -n 50"`
                
                :arrow_forward: *単体再実行コマンド:*
                `./run_ops.sh apply_updates.yml --limit {{ inventory_hostname }}`
                
                ※後続ホストの巻き添えを防ぐため、安全のため本ホストで実行を停止しました。
            status_code: 200
          delegate_to: localhost
          become: no

        - name: Playbookを明示的に失敗ステータスで終了
          ansible.builtin.fail:
            msg: "ホスト {{ inventory_hostname }} のメンテナンス中に異常が発生しました。"
```

---

## 5. 時間帯指定による自動化運用（スケジュール管理）

### 5.1 実行用ラッパースクリプト（`~/ansible-minimalist-ops/run_ops.sh`）

cronからの重複起動を防止する `flock` と、管理サーバー自体の無音停止を検知する **デッドマンズスイッチ（外部死活監視）** を統合しています。

```bash
#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 1. 二重起動防止の排他ロック（fd 200）
LOCK_FILE="/tmp/ansible_minimalist_ops.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "[$(date)] エラー: 他のメンテナンス処理が実行中です。重複実行を防止するため終了します。" >&2
    exit 1
fi

# 2. 仮想環境のロード
source .venv/bin/activate

# 3. 環境変数の設定
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/T00/B00/XXXXX}"
# Healthchecks.io 等のPing URL（空の場合はスキップ）
SNITCH_URL="${SNITCH_URL:-}"

PLAYBOOK="$1"

if [ -z "$PLAYBOOK" ]; then
    echo "使用法: $0 [playbook_name.yml]"
    exit 1
fi

echo "[$(date)] === メンテナンス開始: ${PLAYBOOK} ==="
# 外部監視へ開始通知
[ -n "$SNITCH_URL" ] && curl -fsS -m 10 --retry 3 "${SNITCH_URL}/start" >/dev/null 2>&1 || true

ansible-playbook "playbooks/${PLAYBOOK}" "${@:2}"
EXIT_CODE=$?

echo "[$(date)] === メンテナンス終了 (終了コード: ${EXIT_CODE}) ==="

# 4. 外部監視へ成否ハートビート送信（失敗時はPingを送らず外部からアラート発報させる）
if [ -n "$SNITCH_URL" ]; then
    if [ ${EXIT_CODE} -eq 0 ]; then
        curl -fsS -m 10 --retry 3 "${SNITCH_URL}" >/dev/null 2>&1 || true
    else
        curl -fsS -m 10 --retry 3 "${SNITCH_URL}/fail" >/dev/null 2>&1 || true
    fi
fi

exit ${EXIT_CODE}
```

```bash
chmod +x ~/ansible-minimalist-ops/run_ops.sh
```

### 5.2 crontab スケジュール設定

管理サーバー側で `crontab -e` を実行します。

```cron
# --------------------------------------------------------------------------
# 1. 監視・通知 (毎日 09:00 と 15:00 に未適用セキュリティ更新をスキャン)
# --------------------------------------------------------------------------
0 9,15 * * * /home/opsadmin/ansible-minimalist-ops/run_ops.sh check_updates.yml >> /var/log/ansible_check.log 2>&1

# --------------------------------------------------------------------------
# 2. 自動パッチ適用 ＆ 再起動・ヘルスチェック (毎週日曜 深夜 AM 03:00 に実施)
# --------------------------------------------------------------------------
0 3 * * 0 /home/opsadmin/ansible-minimalist-ops/run_ops.sh apply_updates.yml >> /var/log/ansible_apply.log 2>&1
```

### 5.3 ログローテーション設定（`/etc/logrotate.d/ansible-ops`）

```text
/var/log/ansible_*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    copytruncate
}
```

---

## 6. 【フェーズ2：次期展開】Windows 端末・サーバーの保守管理

Linuxの運用が定着した後、同一基盤にWindowsを追加します。

### 6.1 接続方式の選定と注意点
* **推奨：OpenSSH for Windows**:
  Windows 10 / Server 2019以降はOS標準機能でOpenSSHサーバーが利用可能です。これを用いると、**Linuxと同一のSSH公開鍵認証・ポート（22）で統一**でき、ファイアウォールや証明書管理の負債を最小化できます。
* **WinRMを利用する場合**:
  HTTP（5985）は社内LANであっても平文クレデンシャルが流れるリスクがあるため、HTTPS（5986）を基本とします。自己署名証明書を使う場合はインベントリで `ansible_winrm_server_cert_validation=ignore` を指定します。
* **スリープ状態への配慮**:
  クライアントPC（ノートPC等）は夜間にスリープしているため、夜間cronが通りません。Wake-on-LAN（WoL）の導入か、昼休み（12:00〜13:00）等のアクティブ時間帯を実行枠とします。

### 6.2 Windows更新監視Playbook（`playbooks/win_check_updates.yml`）

```yaml
---
- name: Windows 更新状態スキャンと通知
  hosts: windows_servers
  gather_facts: no
  vars:
    slack_webhook_url: "{{ lookup('env', 'SLACK_WEBHOOK_URL') | default('', true) }}"

  tasks:
    - name: Windows Update の検索（インストールは行わない）
      ansible.windows.win_updates:
        category_names:
          - SecurityUpdates
          - CriticalUpdates
        state: searched
      register: win_updates_check

    - name: 更新通知 (Slack)
      when:
        - win_updates_check.found_update_count > 0
        - slack_webhook_url != ""
      ansible.builtin.uri:
        url: "{{ slack_webhook_url }}"
        method: POST
        body_format: json
        body:
          text: |
            :warning: *【要対応】Windows セキュリティ更新検知*
            ・対象ホスト: `{{ inventory_hostname }}` ({{ ansible_host | default(inventory_hostname) }})
            ・未適用更新件数: *{{ win_updates_check.found_update_count }}* 件
        status_code: 200
      delegate_to: localhost
      become: no
```

### 6.3 Windowsパッチ適用Playbook（`playbooks/win_apply_updates.yml`）

```yaml
---
- name: Windows サーバー・端末の更新と再起動
  hosts: windows_servers
  serial: 1
  tasks:
    # 1. 重要セキュリティ更新の自動検索・インストール
    - name: 重要セキュリティ更新の適用
      ansible.windows.win_updates:
        category_names:
          - SecurityUpdates
          - CriticalUpdates
        reboot: yes                   # 多重再起動もAnsibleが自動待機
        reboot_timeout: 1200          # Windows Updateの再起動待機（最大20分）
      register: update_result

    # 2. ヘルスチェック（必須サービスの稼働確認）
    - name: 必須サービスの稼働確認
      ansible.windows.win_service:
        name: "{{ item }}"
        state: started
      loop:
        - LanmanServer
        - WinRM

    - name: 完了メッセージ
      ansible.builtin.debug:
        msg: "Windowsホスト {{ inventory_hostname }} のパッチ適用と再起動復帰が完了しました。"
```

---

## 7. 【フェーズ3：将来拡張】Mac（macOS）端末の構成管理

### 7.1 前提と現実的な役割分担（MDMとの棲み分け）

> [!WARNING]
> **Apple Silicon (M1/M2/M3/M4) 環境における制約**:
> 近年のmacOSでは、`softwareupdate` によるOSメジャー/マイナーアップデートや再起動の実行に **「Secure Token」** や **「ユーザー所有権（Ownership）」**、あるいはパスワード入力プロンプトが要求され、SSH経由の完全ヘッドレス実行がブロックされるケースが多くなっています。
> 
> そのため本プロジェクトでは、**「OS本体のアップデートは素直にMDM（Jamf Pro, Microsoft Intune, Kandji等）に任せ、AnsibleはHomebrewや開発CLI環境の自動更新・監査に専念させる」** 役割分担を強く推奨します。

### 7.2 macOSツール保守Playbook（`playbooks/mac_apply_updates.yml`）

```yaml
---
- name: macOS 端末の開発環境・CLIツール一括更新
  hosts: mac_clients
  gather_facts: yes
  become: no
  vars:
    homebrew_prefix: "{{ '/opt/homebrew' if ansible_architecture == 'arm64' else '/usr/local' }}"
  environment:
    PATH: "{{ homebrew_prefix }}/bin:{{ homebrew_prefix }}/sbin:{{ ansible_env.PATH }}"

  tasks:
    # 1. Homebrew パッケージの一括アップグレード（ユーザー権限で実行）
    - name: Homebrew パッケージとCaskの更新
      community.general.homebrew:
        update_homebrew: yes
        upgrade_all: yes

    - name: 不要なキャッシュ・旧バージョンのクリーンアップ
      ansible.builtin.command: "{{ homebrew_prefix }}/bin/brew cleanup"
      changed_when: false
```

---

## 8. トラブルシューティング

| 事象 | 原因 | 対処方法 |
| :--- | :--- | :--- |
| **「外部ネットワーク・DNSの名前解決が失敗しました」と出て中断した** | 深夜帯のプロバイダ瞬断、社内FW・DNS障害、または外部リポジトリ障害 | ネットワーク復旧後に再実行。OS側は一切変更されていないため安全に再開可能 |
| **事前チェックで「ディスク容量不足」「iノード枯渇」となり中断した** | `/` や `/boot` に古いカーネルやログ、セッションファイルが溜まっている | 不要ログや古いカーネルパッケージのクリーンアップ（`apt autoremove --purge` や `dnf remove --duplicates`）を実施後に再実行 |
| **「パッケージ管理DBの事前健全性チェック」で中断した** | 過去の手動更新や異常終了により、未完了のパッケージトランザクションが残存している | Debian/Ubuntuなら `sudo dpkg --configure -a`、RHELなら `sudo dnf-complete-transaction` を実機で実行して修復 |
| **「パッチ適用後のsudo特権昇格テスト」で中断した** | `sudo` や `pam`、`sshd` パッケージの更新時に設定不整合が発生した可能性 | **再起動前であればSSHセッションが維持されている可能性あり**。Slack通知記載のワンライナーで即座にログインし、`/etc/sudoers` や `/etc/pam.d` を確認 |
| **再起動後の深層Webヘルスチェックで失敗する** | アプリケーションが起動完了していないか、DB接続エラー等で期待する本文キーワードが返っていない | サーバーにログインし、`journalctl -u nginx` やアプリログを確認。Slack通知記載の単体コマンドで調査 |
| **「他のメンテナンス処理が実行中です」と出てcronが即終了した** | 前回のPlaybook実行がタイムアウト等でまだ完了していないか、プロセスが残存している | `ps aux \| grep ansible` で残存プロセスを確認。異常終了でロックが残っている場合は `/tmp/ansible_minimalist_ops.lock` を確認 |
| **Windows接続時に `winrm` 認証エラー** | 証明書不整合またはBasic認証の未許可 | `ansible_winrm_server_cert_validation=ignore` を確認。またはより安全・簡潔な **OpenSSH for Windows** への移行を検討 |

---

## 9. Docker によるローカル統合テスト（CI/CD検証）

本リポジトリには、実機サーバーを用意することなく、手元のPC（macOS / Linux）で本番同様の自動更新・事後検証サイクルを安全にテストできる Docker 統合テストスイートが付属しています。

### 9.1 テスト環境の構成
* **Target コンテナ（`web01`）**: 本物の `systemd` が PID 1 で稼働する Ubuntu 24.04。SSHサーバー、Nginx、sudo、`opsadmin` ユーザーを初期設定。
* **Manager コンテナ（`manager`）**: 手順書「3.1」の環境を完全再現した Ansible コントローラーノード。

### 9.2 テストの実行方法

リポジトリ直下で以下のコマンドを叩くだけで、鍵生成からコンテナ起動・監視・更新・深層検証・クリーンアップまでが全自動で実行されます。

```bash
./tests/run_tests.sh
```

### 9.3 テストで検証される項目
1. **SSH鍵認証＆特権昇格**: `opsadmin` での鍵接続およびパスワードなしsudoの動作。
2. **監視Playbook（`check_updates.yml`）**: 脆弱性スキャンおよび `/tmp/audit_*.json` レポート出力。
3. **安全更新Playbook（`apply_updates.yml`）**:
   * 外部DNS疎通確認（第0防衛線）
   * ディスク容量＆iノード枯渇チェック（第1防衛線）
   * パッケージ管理DB事前チェック（`dpkg --audit`）
   * LBヘルスチェック退避（安全なトラフィックドレイン）
   * 非対話OSアップデート
   * SSHロックアウト防止テスト
   * Nginxサービス＆深層Webヘルスチェック（HTTP 200 + 本文検証）
   * LBヘルスチェックファイルの正常復帰

