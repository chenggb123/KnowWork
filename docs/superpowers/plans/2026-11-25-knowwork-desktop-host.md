# KnowWork 桌面端 计划 C：本机执行宿主 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** 让对话真正在用户电脑上执行——Electron 主进程拉起本机 DSH 宿主，宿主读写用户选择的文件夹、执行本地命令（先问本人），会话事件回传服务端（网页可看）。

**Architecture（侦察后确定）：**

```
KnowWork 服务端 ──OAuth/设备会话(合同体·事件上行)/工具/技能/模型──> Electron 主进程（"mini 业务服务"）
                                                                     │ 本地 HTTP + 随机令牌（回环）
                                                                     ▼
                                                          本机 DSH 宿主（Node 子进程）
                                              dsh-sdk-minimal + @knowwork/dsh-host（通用层，vendor）
                                              + @knowwork/desktop-host-bundle（新环境层）
                                                                     │
                                                                     ▼  本机文件 / 命令（先审批）
```

关键复用点（已验证）：
- 宿主启动 = DSH profile 装配（`deploy/runtime-host/entrypoint.sh` 的做法：拷 profile 模板 + node_modules link 插件 + `dsh --profile`）。
- 收件入口 = 通用层 `intake.mjs`：`sessionContractOf(body)` / `provision(contract)` / `createTurnIntake({models, provider, fallbackTimeZone})`（intake.mjs:97/118/146）；HTTP 驱动 = `http-host` 插件。
- 合同体格式与服务端一致：设备路由 `GET .../session`（session_body）与 `POST .../turn`（turn_body）返回的就是宿主收的格式（kernel/wire.py）。
- 令牌：主进程用 OAuth 访问令牌换 tools/skills/model 短期令牌（`/api/auth/oauth/token`，audience），宿主回调公开接口 `/api/extensions/tools|skills`、`/api/model/v1`。
- 事件：宿主把官方会话事件推给主进程 → 主进程 `POST /api/cowork/device/conversations/{id}/events`（计划 A 已交付）。

**Tech Stack:** Node 24、DSH 0.2.2-rc.5（本机宿主 profile）、@knowwork/dsh-host（Apache 2.0 vendor）、Electron 主进程（已有 T2/T3 的 LoginService/KnowWorkApi）。

**Spec:** D:\AI\knowwork\docs\superpowers\specs\2026-11-24-knowwork-desktop-client-design.md（§5.4 本机宿主环境层、§2 G2）

## Global Constraints

- 官方 DSH（~/.dsh、AppData\Roaming\DeepSeek Harness）**绝不触碰**；本机宿主用独立 DSH_HOME（`%APPDATA%\knowwork-desktop\dsh`）。
- 宿主只监听 `127.0.0.1`，每次启动生成随机令牌；主进程与宿主之间所有请求带令牌。
- **文件工具根 = 用户为本会话选择的文件夹**；`bash` 等命令一律 `ask`（经官方审批服务 → 主进程 → 渲染弹窗），用户可见完整命令与工作目录。
- 令牌不进宿主进程内存之外的任何地方（宿主只拿短期令牌，模型/工具的真正凭据仍在主进程与服务端）。
- vendor `@knowwork/dsh-host` 保留 Apache 2.0 署名与来源说明；不改其业务逻辑，差异只在新环境层与主进程桥。
- 测试：纯逻辑 node:test；宿主集成用一次性 profile（tmp）跑真 `dsh` 冒烟（可慢，允许 120s）。
- 末尾换行；每任务一提交。

## 控制器裁定

- **主进程充当"mini 业务服务"**（而不是新写一套宿主合同）：直接复用通用层 http-host 的合同格式，把服务端 `prepare_turn` 的合同体原样转给宿主 → 复用最大化，且合同由服务端唯一真源。
- **vendor 而非 link**：把 `D:\AI\knowwork\runtime-host\plugins\dsh-host` 复制到 `desktop/host/vendor/knowwork-dsh-host`（保留 NOTICE 署名），固定版本，DSH 升级时手动同步。
- **M1 宿主能力**：官方 filesystem/subprocess/bash/文件工具/present/jobs/todo/ask-user/skill/subagent/clock/checkpoint/压缩裁剪 + 通用层（回答方式、技能门、工具桥、审批/提问应答、人设、会话策略）。**不含**：定时任务、知识库目录（M2）。
- **文件夹选择**：M1 每会话一个工作文件夹（用户在桌面端选中后创建/进入对话）；默认不给整个磁盘。

## Review Focus

- 文件/命令越出所选文件夹 → 必须被 DSH filesystem 根限制 + bash 审批兜底（Task 3/4 测试）。
- bash 未审批就执行 → 不可接受（Task 4 断言 policy=ask 且审批链路活）。
- 令牌泄漏到宿主/日志/渲染 → Task 2/5 grep 断言（宿主只拿短期令牌）。
- 宿主崩溃/退出后主进程卡死或事件丢失 → Task 5 恢复语义。
- 事件乱序/重复导致服务端拒绝 → Task 5 按 seq 递增、≤500 批、断点续传（用 `GET position`）。
- 本机宿主写用户真实数据目录（不在专用 DSH_HOME）→ Task 1 断言。

---

### Task 1: 宿主 profile 装配与启动

**Files:** Create: `desktop/host/profile/{package.json,cordis.yml,cordis.patch.yml,pnpm-workspace.yaml}`、`desktop/host/launch.mjs`、`desktop/host/vendor/`（vendor 通用层 + NOTICE）、`desktop/test/host-launch.test.mjs`

**Interfaces:**
- Consumes: `D:\AI\knowwork\runtime-host\profile\*`（模板）、`runtime-host\plugins\dsh-host`（vendor）、`runtime-host\plugins\host-bundle\cordis.patch.yml`（服务端环境层，**要改写成本机版**——见 Task 3）。
- Produces: `assembleProfile({dshHome, hostDir, port, token}) -> profileDir`（幂等：每次启动重建 profile 子目录、保留 DSH_HOME 下 sessions 等）；`startHost({dshHome, profileDir, env}) -> {proc, port, token}`；`waitHealthy({port, token, timeoutMs})`。

- [ ] **Step 1: vendor**：复制 `plugins/dsh-host` → `desktop/host/vendor/knowwork-dsh-host`（含 src/skills/common.patch.yml）；写 `desktop/host/vendor/NOTICE`（Apache 2.0、来源 commit/日期、修改说明=无）。
- [ ] **Step 2: profile 模板**：照 `runtime-host/profile`（package.json bundles = dsh-sdk-minimal + @knowwork/dsh-host + @knowwork/dsh-host-bundle；cordis.yml 空根；pnpm-workspace.yaml 照抄）；环境层包 `desktop/host/env-layer`（Task 3 填内容，本任务先占位 patch）。
- [ ] **Step 3: launch.mjs**：`assembleProfile` 建 `$DSH_HOME/profiles/knowwork-desktop`（node_modules/@knowwork/* 链接到 vendor 与本仓 env-layer；拷 profile 四件套）；`startHost` 用 `dsh --profile knowwork-desktop`（`DSH_HOME` 注入、bind 127.0.0.1、随机令牌 env）；`waitHealthy` 轮询 `/health`（通用层 http-host 提供）。
- [ ] **Step 4: 测试**：assembly 幂等（两次调用文件集一致）、断言 DSH_HOME 指向传入路径、断言 profile 引用三个 bundle、断言端口/令牌来自参数。真启动一次 `dsh` 冒烟（120s 超时；成功=health 200；失败记录 stderr 前 40 行）。
- [ ] **Step 5: 提交** `feat(host): 本机宿主 profile 装配与启动`

---

### Task 2: 主进程桥服务（合同转递 + 令牌供给 + 事件上行）

**Files:** Create: `desktop/app/src/bridge/server.js`（本地 HTTP 服务，宿主回调它）、`desktop/app/src/bridge/session.js`、`desktop/test/bridge.test.mjs`

**Interfaces:**
- Consumes: `KnowWorkApi`（T3 计划 B）、`LoginService`、host 的 http-host 合同（通用层）。
- Produces: `class BridgeServer`：`start({port}) -> {port, token}`；路由（全部校验 `Authorization: Bearer <bridgeToken>`）：
  - `POST /v1/sessions`、`POST /v1/sessions/{id}/turns`（宿主收件入口：主进程在此调用服务端 `prepare_turn` 拿合同后**原样返回**，或反过来由主进程主动 push 合同 —— 按 http-host 实际形态接线）
  - `GET /v1/sessions/{id}/models`、`POST /v1/sessions/{id}/tool-credential`、`/skill-credential`（宿主取令牌 → 主进程调 exchange 后返回短期令牌）
  - `POST /events`（宿主上报会话事件 → 主进程 `pushEvents` 到服务端，按 seq 批量 ≤500）
  - `POST /approvals`、`POST /questions`（宿主请求审批/提问 → 主进程转渲染层，等用户 → 回传）
- 明确：**bridge token ≠ 服务端令牌**；宿主只拿短期受众令牌。

- [ ] **Step 1: 读通用层 http-host 的路由表**（`vendor/knowwork-dsh-host/src/http-host.mjs`）钉死宿主期望的路径/形状，不猜。
- [ ] **Step 2: 测试**（mock KnowWorkApi/LoginService）：令牌校验 401；合同转递原样；事件批量与 seq；审批往返（挂起→用户决定→回传）；budget（事件过多分批）。
- [ ] **Step 3: 实现**；`npm test` 通过。
- [ ] **Step 4: 提交** `feat(bridge): 主进程桥服务（合同/令牌/事件/审批）`

---

### Task 3: 桌面环境层（本机执行世界）

**Files:** Create: `desktop/host/env-layer/{package.json,cordis.patch.yml,src/*.mjs}`、`desktop/test/env-layer.test.mjs`

**Interfaces:** Consumes: 通用层 `common.patch.yml`（回答方式/技能/工具桥/审批应答者等）+ 服务端 `host-bundle/cordis.patch.yml`（照它抄，做本机差异）。

**差异清单（相对服务端环境层）：**
- **不停用** `filesystem` / `subprocess` / `bash`（本机执行）；`filesystem` 根 = 会话工作文件夹（主进程建会话时传入）。
- 停用 `sdk-app-startup` / `sdk-jsonrpc-server`（同服务端），收件入口 = http-host（绑 127.0.0.1 + bridge token）。
- 审批/提问：通用层 `approval-broker`/`question-broker` 照挂，决定来源经 HTTP 回调主进程（`/approvals`、`/questions`）——写 env 层插件接线。
- 模型：`dsh-llm-pi-ai` provider 指向 bridge（主进程再转服务端模型网关 `/api/model/v1`），apiKeyEnv 由主进程注入短期 model 令牌。
- 工具桥/技能提供方：指向 bridge 的 `/v1/sessions/{id}/tool-credential|skill-credential`，再由主进程回调服务端公开接口。
- 人设/语言/时钟/检查点/压缩裁剪/`present`/`jobs`/`todo`/`ask-user`/`skill`/`subagent`：照服务端环境层挂法。
- bash 审批：`user-approval` policy `ask`（默认即 ask），命令弹窗展示完整命令 + cwd。

- [ ] **Step 1: 抄服务端环境层**（`host-bundle/cordis.patch.yml` 258 行）→ 本机版，逐条标注「同/改/去掉」，写进 `env-layer/README.md` 对照表。
- [ ] **Step 2: 写接线插件**（审批/提问决定来源、令牌来源、filesystem 根）与测试（纯逻辑：决策映射、根路径校验、令牌注入不落盘）。
- [ ] **Step 3: 真宿主冒烟**：`assembleProfile` + `startHost`（用 Task 2 的 bridge 桩）→ health 200 → 建一个会话 → 断言 `bash` 工具在清单里、`filesystem` 未停用。
- [ ] **Step 4: 提交** `feat(host): 桌面环境层（本机文件/命令 + 审批接线）`

---

### Task 4: 文件夹选择与审批 UI

**Files:** Create: `desktop/app/src/pages/workspace.html`（或并入引导页）、`desktop/app/src/approval.js`、`desktop/test/approval.test.mjs`；Modify: `window.js`（审批气泡/弹窗）、`main.js`

**Interfaces:** `chooseWorkspaceFolder() -> path|null`（`dialog.showOpenDialog`，只目录）；`ApprovalBroker`（主进程）：挂起请求 → 渲染层弹窗（命令全文 + cwd）→ 返回 allow/deny/allow-session；拒绝时回宿主 `deny` 并把原因交给模型。

- [ ] **Step 1: 测试**（纯逻辑）：allow/deny/allow-session 映射、超时（30 分钟）按拒绝、渲染层未就绪时 fail-closed。
- [ ] **Step 2: 实现** + 真 Electron 冒烟（截图：选文件夹 → 发一条要 bash 的消息 → 弹窗出现）。
- [ ] **Step 3: 提交** `feat(desktop): 工作文件夹选择与审批弹窗`

---

### Task 5: 端到端本机执行与事件回传

**Files:** Create: `desktop/docs/verify-C.md`；Modify: `main.js`（会话生命周期接线）、README

- [ ] **Step 1: 串联**：桌面端建设备对话（服务端 201）→ `prepare_turn` 拿合同 → 喂宿主 → 宿主执行（读本机文件、生成一个文件并 `present`）→ 事件上行 → 服务端 `GET position` 递增。
- [ ] **Step 2: 验证清单**：① 命令在所选文件夹内执行（`pwd` 证据）② 越界文件读取被拒/审批 ③ 生成文件出现在服务端产物 ④ 网页端能看到该设备对话与产物 ⑤ 宿主 kill 后主进程报告并允许重开 ⑥ ~/.dsh 零写入、官方 DSH 零干扰。
- [ ] **Step 3: README**：本机执行说明、文件夹语义、审批语义、宿主故障排查（日志位置 `%APPDATA%\knowwork-desktop\dsh`）。
- [ ] **Step 4: 提交** `docs(desktop): 计划 C 端到端验证与说明`