# Lark (Larksuite / Feishu) - Claude Code チャンネルプラグイン

Lark ボットを Claude Code に接続する MCP サーバー。

ボットがメッセージを受信すると、MCP サーバーが Claude に転送し、返信・リアクション・メッセージ編集のツールを提供します。**Lark**（国際版）と **Feishu / 飛書**（中国版）の両方に対応。

## LLM向け

AIアシスタントがこのプラグインのインストールを支援する場合は、[llms.md](./llms.md) を参照してください。自動インストール手順が記載されています。

## 前提条件

- [Bun](https://bun.sh) — `curl -fsSL https://bun.sh/install | bash` でインストール

## セットアップ手順

> シングルユーザーDMボットのデフォルト設定。グループやマルチユーザーの設定は [ACCESS.md](./ACCESS.md) を参照。

**1. Lark アプリとボットを作成**

[Lark Open Platform](https://open.larksuite.com/app)（中国版: [Feishu Open Platform](https://open.feishu.cn/app)）で **Create Custom App** をクリック。

**Features** → **Bot** でボット機能を有効化。

**2. 権限を設定**

**Permissions & Scopes** で以下を追加:

- `im:message` — DM・グループチャットのメッセージ読み取りと送信
- `im:message:readonly` — DM・グループチャットのメッセージ読み取り
- `im:message:send_as_bot` — アプリとしてメッセージ送信
- `im:message.group_at_msg:readonly` — グループでボットへの@メンションメッセージ取得
- `im:message.group_msg` — グループチャットの全メッセージ読み取り（グループでの `fetch_messages` に必要）
- `im:message.p2p_msg:readonly` — ボットへのDMメッセージ取得
- `im:resource` — 画像・ファイルの読み取りとアップロード
- `im:chat` — グループ情報の取得と更新
- `im:chat:readonly` — グループ情報の取得

バージョンを公開し、承認する（自作アプリはテナント管理者の承認が必要）。

**3. イベントサブスクリプションを有効化**

**Events & Callbacks** → **Event Configuration**:
- **"Receive events through persistent connection"** を選択（推奨）
- **Add Events** → `im.message.receive_v1`（メッセージ受信）を追加
- Save

公開URL、暗号化、Webhook設定は不要 — SDK が WebSocket で全て処理します。

**4. アプリのクレデンシャルを取得**

**Credentials & Basic Info** から **App ID** と **App Secret** をコピー。

**5. プラグインをインストール**

```bash
git clone https://github.com/MocA-Love/claude-code-lark.git
claude plugin marketplace add /path/to/claude-code-lark
claude plugin install lark@claude-code-lark
```

**6. クレデンシャルを設定**

```
/lark:configure cli_xxxx your_app_secret_here
```

`~/.claude/channels/lark/.env` に `LARK_APP_ID` と `LARK_APP_SECRET` が保存されます。

**7. チャネルフラグ付きで再起動**

セッションを終了し、新しいセッションを開始:

```sh
claude --dangerously-load-development-channels plugin:lark@claude-code-lark
```

**8. ペアリング**

Claude Code 実行中に、Lark でボットに DM を送信 → ペアリングコードが返されます。Claude Code セッションで:

```
/lark:access pair <code>
```

次の DM からアシスタントに届くようになります。

**9. ロックダウン**

ペアリングは ID 取得用。完了したら `allowlist` に切り替え:

```
/lark:access policy allowlist
```

## Feishu（中国版）の設定

```
/lark:configure domain open.feishu.cn
```

API ベース URL が `open.larksuite.com` から `open.feishu.cn` に変更されます。

## アクセス制御

詳細は **[ACCESS.md](./ACCESS.md)** を参照。

- ユーザーID: Lark の **open_id**（例: `ou_xxxx`）
- チャットID: **chat_id**（例: `oc_xxxx`）
- デフォルトポリシー: `pairing`
- グループチャット: chat_id 単位でオプトイン

## アシスタントに公開されるツール

| ツール | 機能 |
| --- | --- |
| `reply` | チャットに送信。`chat_id` + `text`、オプションで `reply_to`（スレッド）、`files`（添付ファイル） |
| `react` | メッセージにリアクション追加。Lark絵文字名を使用（THUMBSUP, HEART, SMILE 等） |
| `edit_message` | ボットが送信したメッセージを編集 |
| `fetch_messages` | チャットの最近の履歴を取得（古い順、最大50件） |
| `download_attachment` | メッセージの画像/ファイルをダウンロード |

## 環境変数

`~/.claude/channels/lark/.env` に設定:

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `LARK_APP_ID` | Yes | Developer Console の App ID（`cli_` で始まる） |
| `LARK_APP_SECRET` | Yes | Developer Console の App Secret |
| `LARK_DOMAIN` | No | API ドメイン。デフォルト: `open.larksuite.com`。Feishu: `open.feishu.cn` |
| `LARK_ACCESS_MODE` | No | `static` で起動時のアクセス設定を固定 |

## アーキテクチャ

```
ユーザー (Lark) → Lark Cloud ←WebSocket→ Lark SDK (WSClient)
                                              ↓
                                        MCP Server ←stdio→ Claude Code
                                              ↓
                                        Lark REST API → ユーザー (Lark)
```

公開URLは不要。SDK が Lark サーバーへの永続的な WebSocket 接続を維持します。

## 複数セッションと `/lark:takeover`

Larkメッセージを受信できるのは一度に1つのClaude Codeセッションのみ。プラグインはロックファイル（`~/.claude/channels/lark/ws.lock`）で排他制御し、最初に起動したセッションが接続を保持する。

別のセッションにLark接続を切り替えるには、切り替え先のセッションで:

```
/lark:takeover
```

現在のセッション状況を確認するには:

```
/lark:takeover status
```

各プラグインプロセスは `~/.claude/channels/lark/sessions/` にPID・作業ディレクトリ・起動時刻を登録する。takeover スキルはこのレジストリを読むことでセッションを即座に特定する（プロセスツリーの探索不要）。

約3秒で前のセッションが接続を解放し、現在のセッションに切り替わる。作業中のセッションに切り替えれば、そのコンテキストを持ったままLarkから操作を続行できる。

### ゾンビ接続

`kill -9`（SIGKILL）でセッションが終了した場合、ロックファイルやセッションファイルが残る可能性がある。他のセッションがプロセスの死亡を自動検知してクリーンアップする。手動で対処する場合:

```bash
# Larkプラグインのプロセスを確認
ps aux | grep "bun.*server.ts" | grep -v grep

# ゾンビプロセスを終了
kill <pid>
```

## 開発

### プラグインキャッシュ

Claude Codeはインストール済みプラグインを `~/.claude/plugins/cache/` にキャッシュする。ローカル開発時、ソースファイルの変更は**自動的に反映されない**。変更後にキャッシュを削除すること:

```bash
rm -rf ~/.claude/plugins/cache/claude-code-lark/
```

その後、Claude Codeセッションを再起動する。

## ライセンス

Apache-2.0
