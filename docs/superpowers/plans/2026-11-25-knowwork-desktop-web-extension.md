# KnowWork 桌面端 计划 D：网页端「本机」入口插槽包 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** 让用户在 KnowWork 网页对话里直接选择「本机」执行——发消息 → 本机 DSH 宿主干活（审批弹窗）→ 事件回流网页可见。完成「一个后台两个入口」的体验闭环。

**Architecture:** 前端插槽包（`@knowwork/desktop-web`）经 `KNOWWORK_WEB_EXTENSIONS` 构建进 web 镜像，用 `chat.sources` 插槽登记「本机」来源；来源的所有操作（发轮/停止/审批/回答/文件读）经 `preload` 桥 → IPC → Electron 主进程（T4 已备 `runtime.sendTurn` 等）→ 本机宿主 → 事件上行服务端 → 网页通过现有事件流看到。

**Tech Stack:** React 19 + TS（插槽包，复用 `@knowwork/web` 核心组件）、Vite（别名注入）、Electron IPC、knowwork web 镜像构建（gateway.Dockerfile）。

**Spec:** D:\AI\knowwork\docs\superpowers\specs\2026-11-24-knowwork-desktop-client-design.md（§5.2 前端插槽包、§2 G1/G3）

## 已侦察的关键接口（实现者直接用，不要重新猜）

- 插槽注册：`web/src/slots/registry.ts` 的 `install(register)`；`register` 支持 `chat.sources`（登记对话来源）。
- 构建注入：`web/vite.config.ts:9,45` —— `KNOWWORK_WEB_EXTENSIONS` 环境变量 → 别名 `@knowwork/extensions`（缺省 `src/slots/none.ts`）；`@knowwork/web` → `web/src`（可复用核心组件）。
- 来源接口（`web/src/features/chat/sources.ts`）：
  ```ts
  interface ConversationSource {
    id: string; label: string; description: string; Icon?: ComponentType; server: boolean;
    limits?: InputLimits; Picker?: ComponentType; Controls?: ComponentType<{conversationId: string}>;
    welcome?: string; footnote?: string; useBlocker?: () => string | null;
    start: (input: StartInput) => Promise<string>;       // 建对话并起第一轮，返回 conversationId
    dropFiles?: (...) => ...;                             // 可选
    actions: ConversationActions;                         // 见下
    files?: ConversationFiles;                            // 文件读/存/打开/编辑
  }
  interface ConversationActions {
    check: (conversationId) => Promise<string | null>;     // null=可在这里继续；字符串=原因（不能继续）
    send: (conversationId, turn: TurnRequest) => Promise<string | undefined>;
    cancel: (conversationId) => Promise<void>;
    decide: (…批准/拒绝…) => Promise<void>;                // 审批
    remembersApprovals?: boolean;
    answer: (…提问回答…) => Promise<void>;
  }
  ```
- 内置 `DEVICE_SOURCE = 'device'` 已存在（`web/src/api/conversations.ts:26`），设备对话在别处只读；本插槽包要登记的是**可在本机继续**的「本机」来源（id 可用 `device`，或新 id 并在服务端映射）。
- Electron 侧已备：`runtime.sendTurn/stop/approve/answer`（T4）、preload 桥（现有 `getConfig/onLoginState/openExternal/getDeviceId/setServerUrl/requestLogin`，需扩）。

## Global Constraints

- **不改 KnowWork 核心源码**：只加插槽包 + 改构建配置（`deploy/docker/gateway.Dockerfile` 加 build arg / compose 传参）。
- 插槽包只能经 `@knowwork/web` 导入核心（不复制核心组件）；令牌不可见（渲染层只经 IPC 调主进程，主进程持有）。
- 普通浏览器（无 preload 桥）时**不登记**「本机」来源——网页端行为不变。
- 本机来源的审批必须弹窗（复用 T4 的 ApprovalBroker）；拒绝即 deny。
- 测试：插槽包单测（vi.mock 桥）+ 主进程 IPC 单测；构建产物验证（web 镜像里扩展入口存在）。
- 末尾换行；每任务一提交。

## 控制器裁定

- **不改 KnowWork 仓库源码**，构建参数从 `docker-compose.cowork.yml` 的 build args 传入（gateway 镜像 build 时 `--build-arg KNOWWORK_WEB_EXTENSIONS=<包入口>`）；若 gateway.Dockerfile 不支持 build arg，则以最小改动加一个 ARG（属部署配置，允许）。
- M1 的「本机」来源只做核心路径：发轮/停止/审批/回答 + 文件读预览；`files.edit/watch/dropFiles` 留 M2。
- 插槽包代码放 cowork 仓库 `desktop/web-extension/`；web 镜像构建时以 volume/COPY 方式引入（不改 knowwork 仓库的文件树——用 compose 的 build context 或构建前 copy 到 web 仓库的 `.extensions/` 并 .gitignore）。

## Review Focus

- 普通浏览器出现「本机」入口 → 不可接受（Task 1 断言无桥时不登记）。
- 审批不经弹窗（自动允许）→ Task 3 测试。
- 令牌出现在渲染层/preload → Task 2 grep 断言。
- 插槽包破坏核心页面（来源切换、只读态）→ Task 4 冒烟。
- 构建后网页 500/白屏 → Task 4。

---

### Task 1: 插槽包骨架与构建接线

**Files:** Create: `desktop/web-extension/{package.json,src/index.ts,tsconfig.json}`、`deploy/docker/gateway.Dockerfile`（改，允许）、`docker-compose.cowork.yml`（加 gateway build args）；Test: 静态断言

- [ ] **Step 1**: 包骨架——`install(register)` 导出；`register('chat.sources', {...})` 先登记一个**空实现**来源（仅当 `window.knowwork?.bridgeVersion` 存在时）。`package.json` 提供 React peer（复用 `@knowwork/web`）。
- [ ] **Step 2**: 构建接线——gateway 镜像加 `ARG KNOWWORK_WEB_EXTENSIONS`（默认空）+ `ENV`；compose 传 `KNOWWORK_WEB_EXTENSIONS=<包入口绝对路径>`；构建前把 `desktop/web-extension` copy 进 web 构建上下文（compose build context 调整或 Dockerfile ADD）。
- [ ] **Step 3**: 构建一次 gateway 镜像 + 重启 → 无桥的普通浏览器（ego）打开网页断言**看不到**「本机」；desktop 应用内（有桥）断言**看到**。
- [ ] **Step 4**: 提交 `feat(web-ext): 插槽包骨架与构建接线`

---

### Task 2: 「本机」来源实现

**Files:** Create: `desktop/web-extension/src/local-source.tsx`、`bridge.ts`；Test: `desktop/web-extension/test/local-source.test.ts`

- [ ] **Step 1**: `bridge.ts`——`window.knowwork.local.*` 调用的类型化封装（start/send/cancel/decide/answer/readFile/listFolder/workspaceDir）；桥缺失时抛明确错误。
- [ ] **Step 2**: `local-source.tsx`——实现 `ConversationSource`：`id:'device'`（或新 id + 服务端映射）、`label:'本机'`、`description:'在你的电脑上执行，读写所选文件夹'`、`server:true`、`Controls`=显示工作文件夹 + 切换按钮、`start/send/cancel/decide/answer` 全接线、`files.read` 经桥；`useBlocker` 在本机运行时阻止切换执行位置。
- [ ] **Step 3**: 测试（mock 桥）：start 返回 id、send 透传、decide 映射 allow/deny、桥缺失 fail-closed、令牌不在任何返回值。
- [ ] **Step 4**: 提交 `feat(web-ext): 本机来源（发轮/停止/审批/回答/文件读）`

---

### Task 3: preload 桥扩展与主进程 IPC

**Files:** Modify: `desktop/app/src/preload.js`（加 `local` 命名空间）、`desktop/app/src/main.js`、`desktop/app/src/channels.js`、`desktop/app/src/runtime.js`；Create: `desktop/test/local-bridge.test.mjs`

- [ ] **Step 1**: preload 暴露 `local: { start, send, cancel, decide, answer, readFile, listFolder, getWorkspace, chooseWorkspace, onEvent }`（**只传参不含令牌**；事件回调剥 IPC 事件对象）。
- [ ] **Step 2**: 主进程 IPC（全部经 `trustedIpcHandler`）：`start` → `api.createDeviceConversation` + `runtime.openConversation` + `prepareTurn` + `sendMessage`；`send` → `runtime.sendTurn`；`decide/answer` → ApprovalBroker；`readFile` → 经设备路由或本机文件读取（在所选文件夹内）。
- [ ] **Step 3**: 测试：IPC sender 校验、桥面不含令牌、fail-closed（未登录/无文件夹/宿主未就绪）。
- [ ] **Step 4**: 提交 `feat(desktop): 本机桥与 IPC（网页→宿主）`

---

### Task 4: 构建部署与端到端

**Files:** Create: `desktop/docs/verify-D.md`；Modify: `desktop/app/README.md`

- [ ] **Step 1**: 重建 gateway（含插槽包）+ 重启 KnowWork；`npm run dist` 重打桌面包。
- [ ] **Step 2**: 端到端（真应用 + 真服务端，需用户登录）：
  1. 桌面应用里打开网页 → 侧栏/新对话出现「本机」选项（截图）
  2. 选「本机」→ 发一句让它读工作文件夹里的文件 → 宿主执行 → 审批（若需）→ 流式回答在网页里可见
  3. 服务端 `position` seq 递增、产物在网页可预览
  4. 普通浏览器（ego）打开同一网页 → **没有**「本机」入口（回归）
- [ ] **Step 3**: README 更新 + 提交 `docs(desktop): 计划 D 端到端与说明`