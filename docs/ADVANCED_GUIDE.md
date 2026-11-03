# 熟練ユーザー・中上級者のための拡張ガイド ＆ リンク集

> 本プロジェクトのミニマル構成からさらに一歩進め、シークレット暗号化、クラウド連携、CI/CD・AWX統合など、エンタープライズ規模へ拡張するためのリファレンスです。

---

## 1. シークレット管理の強化（Ansible Vault）

現在は環境変数 `SLACK_WEBHOOK_URL` を注入する構成ですが、機密情報をリポジトリ内で安全に暗号化管理する場合は **Ansible Vault** を利用します。

### 文字列単位の暗号化（`encrypt_string`）
Webhook URL や Windows 管理者パスワードなどの機密文字列だけを暗号化して YAML に埋め込めます。

```bash
# パスワードファイルを指定して暗号化文字列を生成
ansible-vault encrypt_string --vault-password-file ~/.vault_pass 'https://hooks.slack.com/services/T00/B00/XXXXX' --name 'slack_webhook_url'
```

出力された `!vault | ...` ブロックをインベントリや変数ファイル（`group_vars/all.yml`）にそのまま貼り付けます。
実行時は `run_ops.sh` に `--vault-password-file ~/.vault_pass` を渡すだけで自動復号されます。

* 📖 [公式ドキュメント: Ansible Vault による暗号化](https://docs.ansible.com/ansible/latest/vault_guide/index.html)

---

## 2. クラウド環境での動的インベントリ（Dynamic Inventory）

サーバー台数が増加したり、Auto Scaling やクラウドリソースの増減が頻繁な場合は、静的な `hosts.yml` ではなく **クラウドのタグ情報を参照する動的インベントリ** に切り替えます。

### AWS EC2 の例（`aws_ec2` プラグイン）
`inventory/aws_ec2.yml`:
```yaml
plugin: amazon.aws.aws_ec2
regions:
  - ap-northeast-1
filters:
  tag:AutoMaintenance: "true"
  instance-state-name: running
keyed_groups:
  - key: tags.Role
    prefix: role
```
「`AutoMaintenance: true`」タグが付いたインスタンスだけを自動抽出し、タグごとにグループ化してメンテナンス対象にできます。

* 📖 [公式ドキュメント: Amazon AWS EC2 Dynamic Inventory](https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html)
* 📖 [公式ドキュメント: Microsoft Azure Dynamic Inventory](https://docs.ansible.com/ansible/latest/collections/azure/azcollection/azure_rm_inventory.html)
* 📖 [公式ドキュメント: Google Cloud Platform (GCP) Dynamic Inventory](https://docs.ansible.com/ansible/latest/collections/google/cloud/gcp_compute_inventory.html)

---

## 3. 管理サーバーの侵害耐性強化と多要素認証（MFA）

Ansible管理サーバーは全配下ノードへの特権アクセス権を持つため、最重要防御対象です。夜間の自動バッチ実行（cron）を無人で回しつつ、外部からの不正アクセスや水平移動（Lateral Movement）を抑え込むための実践的セキュリティ構成です。

### 3.1 管理コントローラーへの SSH 多要素認証（MFA: PAM Google Authenticator）
管理サーバーへの対話的ログイン（SSH）に、パスワード＋スマホのワンタイムパスワード（TOTP）を必須化します。

```bash
# 1. パッケージのインストール (Ubuntu/Debian)
sudo apt update && sudo apt install -y libpam-google-authenticator

# 2. 初期設定の実行 (QRコード生成と秘密鍵の登録)
google-authenticator -t -d -f -r 3 -R 30 -W

# 3. PAM設定 (/etc/pam.d/sshd) に追加
# 末尾に追記:
# auth required pam_google_authenticator.so

# 4. SSHD設定 (/etc/ssh/sshd_config.d/mfa.conf 等) の設定
# KbdInteractiveAuthentication yes
# AuthenticationMethods publickey,keyboard-interactive

# 5. sshd 再起動
sudo systemctl restart ssh
```
* これにより、管理サーバーに人間がログインする際は鍵認証に加えて6桁のMFAコードが求められます。
* コントローラー内部のローカル cron は PAM/SSH を介さないため、夜間の自動パッチ適用は中断されることなく無人で完走します。

### 3.2 ゼロトラストアクセスによる踏み台化（Tailscale / Cloudflare Access）
管理サーバーの SSH ポート（22）をインターネットに直接公開せず、Identity-Aware な VPN / ゼロトラストネットワークを経由させます。

* **Tailscale SSH**: 管理者の Google Workspace や Microsoft Entra ID による SSO + MFA 認証を通過した端末のみが SSH 接続可能になります。
* **Cloudflare Tunnel + Access**: ブラウザ経由または `cloudflared` CLI 経由で IdP 認証を強制し、管理サーバーの IP を隠蔽します。

### 3.3 sudo 権限最小化と Ansible モジュールの関係
Ansible の `become: yes` は、ターゲット側で `sudo python3 ~/.ansible/tmp/...` を実行するため、`/etc/sudoers` でコマンド単位のホワイトリスト（`/usr/bin/apt` のみ等）を設けると標準モジュールは動作しません。

* **標準推奨**: ターゲット側の `authorized_keys` で `from="<Controller-IP>"` を指定して鍵の外部悪用を防ぎ、Ansible ユーザーには `NOPASSWD: ALL` を付与する。
* **極限セキュリティ（コマンド直叩き構成）**:
  Ansible モジュール（`ansible.builtin.apt` 等）の代わりに、Playbook で `become: no` とし `ansible.builtin.command: sudo /usr/bin/apt-get dist-upgrade -y` のように記述。
  ターゲット側の `/etc/sudoers.d/opsadmin` を以下のように固定：
  ```sudoers
  opsadmin ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/sbin/reboot, /usr/bin/systemctl
  ```

### 3.4 ターゲットノードからの逆方向インバウンド遮断
ターゲットノード（Web/DB）が仮に Web アプリの脆弱性で侵入された場合、ターゲットから管理サーバーへ逆侵入されるのを防ぐため、ターゲットから管理サーバーへの通信（Egress / Ingress）をファイアウォールでブロックします。
```bash
# 管理サーバー側で特定管理端末からのみSSHを受け付ける例 (ufw)
sudo ufw default deny incoming
sudo ufw allow from <管理者社内IP> to any port 22
sudo ufw enable
```

---

## 4. UI管理・チーム運用へのステップアップ（AWX / AAP）

cronベースの管理サーバー1台運用から、Web UI、RBAC（権限管理）、監査ログ、スケジューラーを備えたチーム運用へ移行する場合のパスです。

* **AWX (オープンソース)**: Ansibleの公式Web UI/APIサーバー。本リポジトリのGit URLをプロジェクトとして登録するだけで、Web画面からジョブ実行やcronスケジュール管理、権限管理が可能になります。
* **Red Hat Ansible Automation Platform (AAP)**: エンタープライズ向け商用サポート版。

* 📖 [AWX 公式リポジトリ (GitHub)](https://github.com/ansible/awx)
* 📖 [Red Hat Ansible Automation Platform 公式製品情報](https://www.redhat.com/ja/technologies/management/ansible)

---

## 5. オンライン情報・公式リファレンス リンク集

### 公式コアリファレンス
* [Ansible Core 公式ドキュメント（最新版）](https://docs.ansible.com/ansible/latest/index.html)
* [インベントリの構築ガイド（YAML / INI）](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html)
* [Playbook 作成のベストプラクティス](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html)

### 本プロジェクトで使用している主要モジュール仕様
* [`ansible.builtin.reboot` (再起動と復帰ポーリング待機)](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/reboot_module.html)
* [`ansible.builtin.apt` (Debian/Ubuntu パッケージ管理)](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html)
* [`ansible.builtin.dnf` (RHEL/Rocky/AlmaLinux パッケージ管理)](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/dnf_module.html)
* [`ansible.builtin.uri` (HTTPエンドポイント検証)](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/uri_module.html)
* [`ansible.builtin.assert` (事前条件アサーション検査)](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/assert_module.html)
* [`ansible.windows.win_updates` (Windows Update 自動化)](https://docs.ansible.com/ansible/latest/collections/ansible/windows/win_updates_module.html)

### コミュニティ・セキュリティ情報
* [Ansible Galaxy (公式コレクション・ロール共有プラットフォーム)](https://galaxy.ansible.com/)
* [Red Hat Ansible Blog (最新ベストプラクティス・活用事例)](https://www.redhat.com/en/blog/channel/red-hat-ansible-automation-platform)
* [CIS Benchmarks (OS別セキュリティ設定基準)](https://www.cisecurity.org/cis-benchmarks/)
