# claude-code-lark

Lark (Larksuite / Feishu) チャネルプラグインfor Claude Code。

## プロジェクト概要

- Claude Code の Channels 機能を使い、Lark ボット経由でメッセージを送受信する MCP サーバー
- Discord/Telegram 版（`anthropics/claude-plugins-official`）と同じアーキテクチャ
- WebSocket 長接続モード（Lark SDK の `WSClient`）を使用。ngrok/公開URL不要
- Lark（国際版）と Feishu/飛書（中国版）の両方に対応

## 技術スタック

- **ランタイム**: Bun
- **言語**: TypeScript
- **プロトコル**: MCP (Model Context Protocol) — `@modelcontextprotocol/sdk`
- **Lark SDK**: `@larksuiteoapi/node-sdk` — WSClient でイベント受信、REST API でメッセージ送信
- **トランスポート**: stdio（Claude Code ↔ MCP サーバー）

## ファイル構造

```
.claude-plugin/
  plugin.json          # プラグインメタデータ（name: "lark"）
  marketplace.json     # ローカルマーケットプレイス定義
skills/
  configure/SKILL.md   # /lark:configure — クレデンシャル設定
  access/SKILL.md      # /lark:access — アクセス制御管理
.mcp.json              # MCPサーバー起動設定（bun server.ts）
server.ts              # メインMCPサーバー（全ロジック単一ファイル）
package.json           # 依存: @larksuiteoapi/node-sdk, @modelcontextprotocol/sdk
ACCESS.md              # アクセス制御ドキュメント
README.md              # 英語版ドキュメント
README.ja.md           # 日本語版ドキュメント
llms.md                # LLM向け自動インストールガイド
```

## server.ts の構造

上から順に:
1. 定数・環境変数読み込み（`~/.claude/channels/lark/.env`）
2. Lark API ヘルパー（`getTenantToken`, `larkApi`, `validateId`）
3. ボット情報取得（`fetchBotInfo` — 起動時にopen_idとbot名を取得）
4. アクセス制御（`gate`, `loadAccess`, `saveAccess` — pairing/allowlist/disabled）
5. テキスト抽出（`extractTextContent` — 全22メッセージ型対応）
6. 画像キー抽出（`extractImageKey` — image型とpost型埋め込み画像）
7. ファイルダウンロード/アップロード
8. MCPサーバー定義（instructions, tools: reply/react/edit_message/download_attachment/fetch_messages）
9. ツールハンドラ（`CallToolRequestSchema`）
10. メンション置換（`resolveMentions` — @_user_N → @実名）
11. インバウンドメッセージ処理（`handleInbound` — 画像自動DL、リプライ先取得）
12. WebSocket接続（WSClient + EventDispatcher + graceful shutdown）

## Lark API の注意事項

### 権限スコープ（9個）

```
im:message, im:message:readonly, im:message:send_as_bot,
im:message.group_at_msg:readonly, im:message.group_msg,
im:message.p2p_msg:readonly,
im:resource, im:chat, im:chat:readonly
```

- `im:message.group_at_msg` や `im:message.p2p_msg` は単体では存在しない（readonly版のみ）
- 権限追加後はアプリバージョンの再公開が必要

### メッセージ型（全22種）

ボット送信可能: text, post, image, file, audio, media, sticker, interactive, share_chat, share_user, system
受信専用: merge_forward, hongbao, share_calendar_event, calendar, general_calendar, location, video_chat, todo, vote, folder

### content JSON の注意点

- `share_chat`: `chat_id` のみ（`chat_name` は存在しない）
- `system`: `template` フィールド（`text` ではない）
- `location`: `name`, `latitude`, `longitude`（`address` は存在しない）
- `todo`: `summary.title` が空文字列の場合あり → `summary.content` からテキスト抽出
- 画像+テキスト混在メッセージ: `image` 型ではなく `post` 型になる

### chat_id と open_id の違い

- `open_id` (`ou_xxx`): ユーザーID。allowlist に保存
- `chat_id` (`oc_xxx`): チャットID。p2p の chat_id ≠ ユーザーの open_id
- `chat-mapping.json` で chat_id ↔ open_id の対応を管理

## 開発フロー

### プラグインキャッシュ

Claude Code はプラグインを `~/.claude/plugins/cache/claude-code-lark/` にキャッシュする。
ローカル変更後は必ずキャッシュ削除:

```bash
rm -rf ~/.claude/plugins/cache/claude-code-lark/
```

### テスト起動

```bash
claude --dangerously-load-development-channels plugin:lark@claude-code-lark
```

### ゾンビプロセスの確認

```bash
ps aux | grep "bun.*server.ts" | grep -v grep
```

SIGINT/SIGTERM で graceful shutdown 済み。SIGKILL の場合のみ 4-6 分のゾンビが発生。

## 既知の制約

- **複数セッション**: 同一アプリで複数 WSClient 接続するとメッセージがランダムに1つにしか届かない
- **チャネルからCLIコマンド不可**: /clear, /compact, スキル等はターミナル専用。チャネルメッセージは Claude のコンテキストにテキストとして注入されるのみ
- **fetch_messages**: グループチャットで HTTP 400 が発生する場合がある（権限設定の問題）

## 将来の検討事項

- **複数セッション対応**: Lark スレッド (`thread_id`) ベースのルーティング + Agent SDK (`@anthropic-ai/claude-agent-sdk`) でセッション管理。参考: `larksuite/openclaw-lark`
- **追加イベント対応**: `im.chat.member.bot.added_v1`（ウェルカムメッセージ）、`im.message.recalled_v1`（撤回通知）等
- **公式マーケットプレイス**: 申請済み（2026-03-20）、審査待ち

## コーディングルール

- 常に日本語で会話
- コミットメッセージは Conventional Commits（英語）
- コミット・プッシュはユーザーの明示指示がある場合のみ
- server.ts は単一ファイル構成を維持（Discord/Telegram版と同じパターン）
