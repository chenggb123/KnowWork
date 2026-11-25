# KnowWork 桌面端 计划 B：Electron 应用壳 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** 一个 KnowWork 品牌的 Windows Electron 应用：内嵌 KnowWork 网页、OAuth 登录公司账号并持有令牌、封装设备会话 API、可打包分发。本计划**不含本机执行宿主**（计划 C），验收标准是「登录成功 + 能建一条设备会话对话 + 内嵌网页可用 + 打出安装包」。

**Architecture:** Electron 主进程（Node ESM）负责 OAuth PKCE 登录（系统浏览器 + 回环回调）、令牌存储（Electron `safeStorage` 加密后落盘）、令牌交换、设备会话 API 封装、内嵌网页窗口（`BrowserWindow.loadURL(serverUrl)`，cookie 由 Electron session 持久化）。渲染进程直接加载服务端网页，preload 只暴露最小桥。纯逻辑（PKCE、URL、刷新、API 封装）与 Electron 解耦以便 node:test 单测。

**Tech Stack:** Node 24（Electron 内置）、Electron 44、electron-builder（NSIS per-user x64）、node:test（纯逻辑测试，无框架依赖）、Web Fetch（undici 内置）。

**Spec:** D:\AI\knowwork\docs\superpowers\specs\2026-11-24-knowwork-desktop-client-design.md（§5.3 Electron 应用、§5.5 打包）
**API 依据:** C:\Users\cheng\.cowork\bundle\docs\api-notes.md（§4 OAuth、§5 令牌交换、§7 模型清单）+ 计划 A 的 README 契约表（`server-extension/README.md`）

## Global Constraints

- 代码在 `C:\Users\cheng\.cowork\desktop\app`；不碰 KnowWork 仓库（D:\AI\knowwork 只读参考）。
- 令牌只由主进程持有：渲染进程与 preload **永不可见**令牌；磁盘只存 `safeStorage` 加密后的密文（不可用时不落盘，仅内存）。
- 登录只用 OAuth PKCE（公开客户端，无 client_secret）；回调只监听 `127.0.0.1:<随机端口>`，路径 `/callback`；拒非回环/带查询串的伪造回调（移植 `bundle/src/login.mjs` 的校验口径与竞态修复）。
- client_id 固定 `kw-desktop`；`device_name` 传机器名（截断 100 字符）；请求通常自带 `device_id`（首启生成 UUID 持久化）。
- 服务端地址可配置（默认 `http://127.0.0.1:8080`），存 userData 下的 config.json（非机密）。
- 设备会话 API 只在**已验证登录**时调用；401 → 刷新一次 → 仍 401 则回未登录态。
- 新文件末尾换行；每任务一提交；`node --test "desktop/test/*.test.mjs"`（Windows 下 glob 形式）。

## 控制器裁定（默认值，可否决）

- **JS + node:test，不用 TypeScript**：与仓库既有 rebrand/bundle 风格一致，省掉构建步骤（Electron 直接跑 ESM）；类型明确写 JSDoc。
- **Electron 44**（本机官方 DSH 壳同版本，已验证可用）；不引入 React 等前端框架（渲染进程加载服务端网页）。
- **内嵌网页登录与 OAuth 登录是两次登录**（M1 简化，见计划 A Ruling）；M2 再做免二次。
- **preload 最小面**：`getConfig()`（serverUrl/版本）、`onLoginState()`、`openExternal(url)`；计划 D 再扩。
- 打包 per-user NSIS、无签名（README 写 SmartScreen 提示）。

## Review Focus

- 令牌进渲染进程/preload/日志/明文磁盘 → 不可接受（Task 2/4 测试用 grep 断言 + 注入断言）。
- 伪造回调（非回环 host、带 query、非 /callback、state 不符、重复 code）被接受 → 必须拒绝（Task 2 测试）。
- 令牌过期不刷新 / 刷新失败不退出登录 → Task 3 测试。
- 401 后无限刷新循环 → 只重试一次（Task 3 测试）。
- 内嵌网页里点外链在本应用内打开 → 必须交系统浏览器（Task 4）。
- 打包后应用无法启动/白屏 → Task 5 冒烟。

---

### Task 1: 工程骨架与打包配置

**Files:**
- Create: `desktop/app/package.json`、`desktop/app/electron-builder.yml`、`desktop/app/src/main.js`（最小可启动）、`desktop/app/src/preload.js`、`desktop/app/.gitignore`、`desktop/app/README.md`
- Test: `desktop/test/smoke-structure.test.mjs`（结构/清单断言）

**Interfaces:**
- Produces: `npm start` 能起空窗口；`npm test` 跑 node:test；`npm run dist` 出 NSIS；`package.json` 导出 `dsh`? 否——是 Electron app：`"main": "src/main.js"`、`"build"` 指 electron-builder.yml。

- [ ] **Step 1: 骨架**：package.json（`type:module`、main、scripts: start/test/dist、devDependencies: electron@44、electron-builder）；electron-builder.yml（appId `com.knowwork.desktop`、productName `KnowWork`、win target nsis、perMachine false、oneClick false、x64）；src/main.js 起 800×600 窗口加载 `about:blank`；preload.js 空桥。
- [ ] **Step 2: 测试**：静态断言（不启动 Electron）——package.json 的 main/type/scripts、electron-builder.yml 的 appId/productName/target/perUser、main.js 与 preload.js 存在且含关键导出行、preload 不含令牌字样。运行时正确性由 Task 5 冒烟覆盖。
- [ ] **Step 3: 跑过 + 提交** `feat(desktop): Electron 工程骨架与打包配置`

---

### Task 2: OAuth 登录与令牌存储

**Files:**
- Create: `desktop/app/src/login.js`、`desktop/app/src/config.js`、`desktop/test/login.test.mjs`
- Modify: `desktop/app/src/main.js`（启动时若无令牌则触发登录）

**Interfaces:**
- Consumes: 移植口径来自 `C:\Users\cheng\.cowork\bundle\src\login.mjs`（PKCE/回环校验/settled/超时/锁内刷新——读它照抄逻辑，改成 ESM 无 DSH 依赖）。
- Produces:
  - `createPkce() -> { verifier, challenge }`（verifier 43 字符 base64url，challenge=S256）
  - `parseCallbackRequest(rawUrl, { path, state }) -> { ok:true, code } | { ok:false, reason }`（拒非回环/带 query 以外的异常形态/路径不符/state 不符）
  - `class LoginService`：`constructor({serverUrl, clientId, deviceName, deviceId, openBrowser, httpFetch, store, clock})`；`login() -> tokens`、`refresh() -> tokens`、`token() -> string`（自动刷新）、`logout()`、`status() -> {loggedIn}`；`store` 抽象（`save/load/clear`）——生产用 SafeStorageStore，测试用内存桩。
  - `tokens = { accessToken, refreshToken, expiresAt, serverUrl, clientId }`

- [ ] **Step 1: 测试先写**（`node --test`）：
  - PKCE：verifier 43 字符、challenge = base64url(sha256(verifier))
  - 回调校验：`http://127.0.0.1:5/callback` 收；`localhost`/`https`/`10.0.0.1`/带 query/非 /callback/state 不符/重复 code 全拒
  - 登录流：mock openBrowser 捕获 URL（含 client_id=kw-desktop、code_challenge_method=S256、redirect_uri 回环、state）；mock 回环回调 → mock token 端点 → 断言 saved tokens 字段与 expiresAt
  - 刷新：过期后 `token()` 触发 refresh（grant_type=refresh_token）恰一次；并发 3 次只刷 1 次
  - 刷新失败（400 invalid_grant）→ `logout()` 清 store 且 status().loggedIn===false
  - 超时/取消：回调迟到不落库
- [ ] **Step 2: 跑失败**
- [ ] **Step 3: 实现** config.js（读/写 userData/config.json，默认 serverUrl、deviceId UUID 持久化、deviceName=os.hostname() 截断 100）；login.js（照 brief 的接口；回环用 `node:http` 监听 127.0.0.1:0；超时 300s；settled 复查；`AbortSignal.timeout(15000)`）
- [ ] **Step 4: 跑过 + 提交** `feat(desktop): OAuth PKCE 登录与加密令牌存储`

---

### Task 3: 令牌交换与设备会话 API 客户端

**Files:**
- Create: `desktop/app/src/api.js`、`desktop/test/api.test.mjs`
- Modify: `desktop/app/src/login.js`（暴露 `exchange(audience)`）

**Interfaces:**
- Consumes: LoginService.token()；计划 A 的路由契约（`server-extension/README.md` 路由表 + 错误契约）。
- Produces: `class KnowWorkApi`：`constructor({baseUrl, login, fetchImpl})`
  - `exchange(audience) -> {token, expiresIn}`（POST `/api/auth/oauth/token`，form：grant_type=token-exchange、subject_token、subject_token_type、client_id、audience；**缓存到 expiresIn*2/3**，过期前重换）
  - `createDeviceConversation({title})`、`getSession(id)`、`prepareTurn(id, {text, mode?, language?, timeZone?, selection?})`、`deleteConversation(id)`
  - `pushEvents(id, events, session?)`、`pushLive(id, frames)`、`getPosition(id)`、`rememberApproval(id, toolName)`
  - `models()`（`/api/cowork/models`）
  - 所有方法：带 `Authorization: Bearer <accessToken>`；401 → login.refresh() 一次 → 重试一次；仍 401 抛 `UnauthorizedError`；4xx 抛 `ApiError{status, code, detail}`。

- [ ] **Step 1: 测试**：mock fetch 断言 URL/method/body/头；401→refresh→重试恰一次；二次 401 抛 UnauthorizedError；exchange 缓存（两次调用只一次网络、过期重换）；错误映射（429/422/404 detail 透传）；approval 发 `toolName`（驼峰，与开源同款）。
- [ ] **Step 2: 跑失败**
- [ ] **Step 3: 实现 api.js**
- [ ] **Step 4: 跑过 + 提交** `feat(desktop): 令牌交换与设备会话 API 客户端`

---

### Task 4: 内嵌网页窗口与 preload 桥

**Files:**
- Create: `desktop/app/src/window.js`、`desktop/test/window.test.mjs`
- Modify: `desktop/app/src/main.js`、`desktop/app/src/preload.js`

**Interfaces:**
- Produces: `createMainWindow({serverUrl, preloadPath, onLoginState}) -> BrowserWindow`；(a) `loadURL(serverUrl)`；(b) `setWindowOpenHandler` → `{action:'deny'}` 且 `shell.openExternal(url)`（只对 http/https）；(c) `will-navigate` 到非同源 → 阻止 + 外部打开；(d) preload 暴露 `window.knowwork = { getConfig(), onLoginState(cb), openExternal(url), getDeviceId() }`，**不含任何令牌字段**。

- [ ] **Step 1: 测试**（纯逻辑抽出，可单测的部分）：`isSameOrigin(base, target)`、`shouldOpenExternal(url)`（http/https 才 true、javascript:/file:/data:/mailto: 处理）、`navigationPolicy(baseUrl, target) -> 'allow'|'external'|'deny'`。
- [ ] **Step 2: 跑失败**
- [ ] **Step 3: 实现** window.js + main.js 接线（登录成功后才 loadURL 服务端；未登录先显示本地引导页 `src/pages/login.html`——一个按钮触发登录）+ preload.js（contextIsolation 开、nodeIntegration 关、只白名单方法）。
- [ ] **Step 4: 跑过 + 提交** `feat(desktop): 内嵌网页窗口、外链策略与 preload 桥`

---

### Task 5: 打包、端到端验收与交付文档

**Files:**
- Create: `desktop/app/README.md`（构建/使用/SmartScreen/已知限制）、`desktop/docs/verify-B.md`（验收证据）
- Modify: 无（打包配置已在 T1）

- [ ] **Step 1: 打包**：`npm run dist` → `desktop/app/dist/KnowWork Setup <ver>.exe`；记录体积与哈希。
- [ ] **Step 2: 安装冒烟**（本机 per-user）：静默安装 → 启动 → 引导页 → 点登录（浏览器授权）→ 主窗口加载服务端网页（截图）→ 用主进程调试接口或临时脚本调 `createDeviceConversation` 断言 201 且 source=device → `getSession` 200 → 在网页端侧栏看到「本机」标记的该对话（截图）。
  （若用户不便当场授权：记录「待人工」并说明如何验证，不伪造。）
- [ ] **Step 3: 卸载核对**：卸载后安装目录/快捷方式清理；userData（含加密令牌）按 `deleteAppDataOnUninstall:false` 保留，README 说明如何手动清理。
- [ ] **Step 4: 提交** `docs(desktop): 计划 B 验收与交付说明`