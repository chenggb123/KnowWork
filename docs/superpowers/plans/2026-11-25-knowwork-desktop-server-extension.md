# KnowWork 桌面端 服务端扩展（第一版计划 A）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 服务端支持「设备会话」——桌面端在本机执行对话，会话/事件回传服务端统一存储，网页端可看；并完成桌面端 OAuth 登录客户端登记与安装包托管。

**Architecture:** 在现有 knowwork 扩展（`C:\Users\cheng\.cowork\server-extension`，已部署）上扩展：改名 client_id 为 `kw-desktop`；新增设备会话 HTTP 路由，薄封装开源已装配的 `ctx.device_conversations`（DeviceConversations，opensource 只有类没有路由）；复用 ctx.oauth_device_id 判设备归属。不改 KnowWork 核心源码。

**Tech Stack:** Python 3.12、FastAPI、SQLAlchemy async、knowwork v0.1.2 扩展合同、pytest（uv run --project D:\AI\knowwork\server）、Docker 派生镜像。

**Spec:** D:\AI\knowwork\docs\superpowers\specs\2026-11-24-knowwork-desktop-client-design.md（§5.1、§5.6 复用盘点）

## Global Constraints

- 扩展代码只在 `C:\Users\cheng\.cowork\server-extension`；**KnowWork 核心源码零改动**。
- 复用既有测试与部署链（uv run --project D:\AI\knowwork\server pytest；镜像 knowwork-cowork-server:v0.1.2 重建；compose 覆盖已就位）。
- 鉴权：`principal(None)`（bound_principal 认 Bearer kwat_ 或 cookie），设备归属用 `ctx.oauth_device_id(principal.grant_id)`。
- 设备会话判定：只有 `conversation.source == DEVICE_SOURCE` 且归本人；别人/云端对话一律 404。
- 事件批量上限 500 条、序号严格递增（开源 `frames_of` 已强制）；RLS 纪律照现有 exchange.py（in_workspace 前置）。
- 新文件末尾换行；每任务一提交。

## 控制器裁定（简化，可否决）

- **M1 不做 web-session 换取**：Electron 内嵌网页由用户在内嵌页正常登录一次（Cookie 存 Electron session）；OAuth 登录是主进程为设备令牌做的第二次登录。免二次登录（web-session 换取）留 M2——`ApiContext` 未暴露 SessionService，M1 强行换取会引入对 identity 内部模块的深耦合。
- client_id 改名 `kw-desktop`、显示名「KnowWork 桌面端」（旧 `kw-cowork` 不再登记；作废方向的冒烟证据自然失效）。
- 设备注册表（列表/吊销/最低版本）留 M2；M1 复用开源已有「已登录设备」页（/api/auth/devices）。

## Review Focus

- 非本人/云端对话经设备路由可被读到或写入 → 必须 404（Task 2/3 测试）。
- 设备号不符（token 的 grant 无 device_id，或与建对话时不同）→ 拒绝（Task 2）。
- 事件序号乱序/超 500/子会话编号非法 → 400（Task 3）。
- 令牌交换对非成员签出令牌 → invalid_target（已有 Task 3 覆盖，改造后回归）。
- 改名后旧 kw-cowork 仍被接受 → 必须 invalid_client（Task 1 测试）。

---

### Task 1: 改名 kw-desktop 并回归

**Files:**
- Modify: `server-extension/src/cowork_extension/oauth.py`（CLIENT_ID/CLIENT_NAME）
- Modify: `server-extension/tests/test_oauth.py`
- Create: `server-extension/src/cowork_extension/__init__.py`（若需同步 setup_api 注释）

**Interfaces:**
- Produces: 常量 `CLIENT_ID = "kw-desktop"`、`CLIENT_NAME = "KnowWork 桌面端"`；回调路径保持 `/callback`（Electron 回环）。

- [ ] **Step 1: 改测试**：test_oauth.py 断言 CLIENT_ID=="kw-desktop"、CLIENT_NAME 含「KnowWork 桌面端」；加负例「kw-cowork 未登记 → clients.get 为 None」。
- [ ] **Step 2: 跑失败**（`uv run --project D:\AI\knowwork\server pytest C:\Users\cheng\.cowork\server-extension\tests -v`）
- [ ] **Step 3: 改 oauth.py 常量**；同步其它引用（grep kw-cowork / cowork 桌面端）。
- [ ] **Step 4: 全过**（22+ 测试）+ 提交 `refactor(server-extension): 客户端改名 kw-desktop（KnowWork 桌面端）`

---

### Task 2: 设备会话路由（建对话 + 合同体）

**Files:**
- Create: `server-extension/src/cowork_extension/device_api.py`
- Modify: `server-extension/src/cowork_extension/__init__.py`（setup_api 追加 router）
- Create: `server-extension/tests/test_device_api.py`

**Interfaces:**
- Consumes: `ctx.device_conversations`（DeviceConversations：`create(workspace_id,user_id,title,scope)`、`owned(workspace_id,user_id,conversation_id)`、`session(conversation)`、`prepare_turn(conversation, turn, selection)`、`delete`）；`ctx.oauth_device_id(grant_id)`；`exchange.py` 的 `resolve_workspace`；knowwork `kernel.contract.TurnInput`、`profile.snapshot.TurnSelection`。
- Produces:
  - `device_router(ctx, exchange_deps) -> APIRouter`（前缀 `/api/cowork/device`），路由：
    - `POST /conversations` body `{title?}` → `{id, source:"device"}`
    - `GET /conversations/{id}/session` → 开会话合同体（dict）
    - `POST /conversations/{id}/turn` body `{text, selection?}` → `{session?:dict|null, turn:dict}`
    - `DELETE /conversations/{id}` → 204
  - `device_of(principal, ctx) -> str | None` 辅助（grant → device_id）
  - `owned_device_conversation(...)` 辅助：解析空间 + owned()，None 则 404

- [ ] **Step 1: 写失败测试**（用假 ctx：device_conversations 为记录调用的桩，oauth_device_id 返回 "dev-1"，principal 为 SimpleNamespace(user_id="u1", grant_id="g1")）：

```python
# 关键断言
async def test_create_returns_device_conversation(): ...   # 调 create(ws, "u1")，201/200 且 source=="device"
async def test_no_device_rejected(): ...                  # oauth_device_id → None → 403
async def test_foreign_conversation_404(): ...             # owned() → None → 404
async def test_session_body_passthrough(): ...            # session() 返回 dict 原样
async def test_prepare_turn_passes_selection_text(): ...   # TurnInput(text=...), selection 透传
async def test_delete_foreign_404(): ...
```

- [ ] **Step 2: 跑失败**
- [ ] **Step 3: 实现 device_api.py**。鉴权依赖用 `ctx.principal(None)`；空间用 `await resolve_workspace(global_sessionmaker=ctx.global_sessionmaker, sessionmaker=ctx.sessionmaker, user_id=principal.user_id)`；设备校验 `await ctx.oauth_device_id(principal.grant_id)`。
- [ ] **Step 4: 跑过** + 提交 `feat(server-extension): 设备会话路由（建对话/合同体）`

---

### Task 3: 设备事件上行路由

**Files:**
- Modify: `server-extension/src/cowork_extension/device_api.py`
- Modify: `server-extension/tests/test_device_api.py`

**Interfaces:**
- Consumes: `DeviceConversations.push(conversation, events, session=None)`、`push_live(conversation, frames)`、`position(conversation)`；异常 `InvalidEvents`（→400）、`NotOnDevice`（→404）。
- Produces（同前缀）：
  - `POST /conversations/{id}/events` body `{events:[...], session?:string}` → `{position:int|null}`
  - `POST /conversations/{id}/live` body `{frames:[...]}` → 204
  - `GET /conversations/{id}/position` → `{seq:int|null, children:{...}}`
  - `POST /conversations/{id}/approval-grant` body `{tool_name}` → `{remembered:bool}`

- [ ] **Step 1: 写失败测试**：正常一批事件（2 条递增）→ position；乱序 → 400；>500 → 400；子会话编号非法（`session="bad/name"`）→ 400；非本人 → 404；approval-grant 透传 `remember_approval` 返回 bool。
- [ ] **Step 2: 跑失败**
- [ ] **Step 3: 实现路由**（异常映射：InvalidEvents→400 detail 前缀 `invalid_events:`；NotOnDevice/owned None→404）
- [ ] **Step 4: 跑过** + 提交 `feat(server-extension): 设备事件上行与审批授权路由`

---

### Task 4: 重部署 + 契约冒烟

**Files:** Modify: 无（部署操作）；Create: `server-extension/tests/test_device_e2e.py`（可选，pytest 内用 TestClient + 假 ctx 已覆盖则跳过）

- [ ] **Step 1: 重建镜像**：`docker build -t knowwork-cowork-server:v0.1.2 C:\Users\cheng\.cowork\server-extension`（compose 覆盖已指向该镜像）
- [ ] **Step 2: 重启并等健康**：三个 -f 的 compose up -d；`/ready` 200
- [ ] **Step 3: 冒烟**（curl，带真实 OAuth 令牌；无令牌路径先验）：
  1. 无令牌 `POST /api/cowork/device/conversations` → 401
  2. `GET /api/auth/devices`（登录后）仍正常
  3. OAuth authorize 用 `kw-desktop` → 200 含「KnowWork 桌面端」；`kw-cowork` → invalid_client
  4. 下载路由 `/api/cowork/dl/xxx` → 404 仍正常
- [ ] **Step 4: 提交** `chore(server-extension): 设备会话扩展部署冒烟`（若有代码变更才提交）