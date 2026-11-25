# KnowWork 桌面客户端（Windows）设计文档

日期：2026-11-24
状态：**生效**（2026-11-25 恢复）。曾短暂转向「重打包官方 DSH 桌面壳」（见
C:\Users\cheng\.cowork\docs\superpowers\specs\2026-11-24-cowork-desktop-design.md），
该方向已作废：**终端不做 DSH 应用品牌壳**，回到本设计——KnowWork 品牌 Electron 客户端，
内嵌 KnowWork 网页、设备会话回传服务端统一存储；**本机执行运行时内部仍用 DSH**
（KnowWork 同款内核，作为 Electron 主进程管理的 Node 子进程，不重打包 DSH 桌面壳）。
范围：开源 KnowWork（v0.1.2，DSH 0.2.2-rc.5）之上的桌面客户端，团队分发，Windows 单平台。

## 1. 意图与背景

用户要「一个管理后台、两个入口」：网页照旧，桌面客户端在员工自己的电脑上执行任务
（读写本地文件、跑本地命令），但技能广场、MCP 工具、模型目录、权限与审计全部走服务端
同一套。这正是商业版桌面端的形态；本设计在**开源代码已有的扩展点上**把它实现出来，
不 fork 服务端/前端核心，不依赖商业授权。

### 已验证的事实（设计的地基，均指开源仓库内文件）

服务端（server/src/knowwork_server/）：
- `conversations/device.py`：设备会话机制完整——建对话（不开宿主会话）、`session()`/
  `prepare_turn()` 返回与服务端宿主**同一份**合同体（kernel/wire.py）、`push()`/`push_live()`
  收设备事件进同一事件泵（编号/落库/推网页全复用）、`position()` 断点续传、
  `remember_approval()` 记「本会话不再询问」、`models()` 模型清单同步。
  注释明确：「开源这边只有接口：谁能建、谁能送、设备是谁，由扩展判断」。
- `identity/oauth.py` + `oauth_routes.py`：原生应用登录（授权码 + PKCE，RFC 8252/8693），
  OAuthGrant 已带 `device_name`/`device_id`，已有 `list_devices`/`revoke_device`/`revoke_all`、
  刷新令牌 30 天闲置作废、`/api/auth/devices` 接口。
- `identity/oauth_exchange.py`：令牌交换，本机宿主换 model/tools/skills 三种短期令牌。
- `app.py:596-703`：**登记了原生应用就自动挂**公开模型网关、`/api/extensions/tools`、
  `/api/extensions/skills`（device_environment 变体：技能环境变量由本机宿主自取）。
  `ApiContext` 已装配 `device_tokens`（app.py:643 `_device_tokens`，工具去掉 needs_sandbox）、
  `device_conversations`、`oauth_clients`、`oauth_exchangers`、`oauth_devices`、`oauth_device_id`。
- `extensions/loader.py:122`：`license_module = None` 的扩展**不需要授权即启用**。
  扩展 = Python 包 + entry point 组 `knowwork.extensions`，自带 Alembic 迁移分支与 RLS 表清单。
- `tools/registry.py`：`needs_sandbox` 工具自动从设备会话剔除。

前端（web/src/）：
- `slots/registry.ts`：前端插槽机制。构建时 `KNOWWORK_WEB_EXTENSIONS` 环境变量把别名
  `@knowwork/extensions` 指向扩展前端包入口（导出 `install(register)`）；可注册管理后台
  导航/页面（AdminNavEntry）、对话来源等。开源构建所有插槽为空。
- `features/chat/sources.ts`：对话来源注册表，`chat.sources` 插槽供扩展登记「本机」来源
  （操作、文件读/存/打开、工作文件夹、访问模式控件）；内置 DEVICE_SOURCE 在别的机器上只读。
- `features/chat/components/PlaceSelect.tsx`：新对话「在哪执行」选择器（云端/本机）。
- `features/auth/OAuthConsentPage.tsx`：/oauth/authorize 应用登录确认页（必须用户点允许）。
- `features/settings/DevicesSection.tsx`：账号页「已登录的设备」+ 单台退出。
- `utils/shellFileDrag.ts`、`utils/publicOrigin.ts`：外壳（Electron）经 preload 提供的
  原生拖出、外站交系统浏览器等接口，普通浏览器自动降级。

运行时宿主（runtime-host/）：
- `plugins/dsh-host/common.patch.yml`：通用插件层**两端共用**（注释明确桌面端环境层叫
  `@knowwork/desktop-host-bundle`，闭源缺的就是它）：回答方式、知识库目录、会话策略、
  技能提供方/技能门/专业工具解锁、工具桥、审批/提问应答者（answers.mjs 支持「本机经主进程
  私有通道」）、子 Agent 策略继承。
- `plugins/dsh-host/src/intake.mjs`：收合同建会话/发轮的逻辑，注释明确本机宿主由
  「桌面端的收件入口」喂同一份合同体。
- `profile/package.json`：bundles = dsh-sdk-minimal + @knowwork/dsh-host + 环境层。

**结论：协议与插槽全部现成，缺的是四个实现件 + 打包分发。**

## 2. 目标 / 非目标 / 反目标

目标：
- G1 Windows 桌面应用：内嵌服务端网页，登录/权限/模型/技能/工具/审计与网页端同一套。
- G2 本机执行：对话可在本机跑，Agent 读写用户选择的文件夹、执行本地命令（先问本人）。
- G3 会话记录服务端统一存储：本机对话的事件实时回传，网页端可看（只读），换机器不丢历史。
- G4 设备管理（团队分发级）：设备注册绑定到人、管理后台设备列表（版本/活跃/状态）、
  远程吊销、最低版本闸门、从自己服务端下载与自动更新、设备动作进审计。
- G5 不 fork 核心：全部经扩展点（服务端扩展包 + 前端插槽包 + DSH 配置档/插件），
  跟随开源版本升级。

非目标（本期不做）：
- macOS / Linux 客户端；多工作空间（开源版单空间）；
- 本机 Office 生成/编辑引擎（LibreOffice Kit 随包，体积大，列 M3）；
- 流式执行/终端（DSH SSH 执行环境，列 M3 评估）；
- 离线使用（模型/技能/工具都依赖服务端）。

反目标（做成了也算失败）：
- 模型厂商密钥、MCP 凭据落到渲染进程或本机宿主（只有短期令牌）；
- 未经用户确认执行本地命令（「本会话不再询问」必须由用户主动勾）；
- 改动 server/web/runtime-host 核心源码导致升级冲突；
- 本机文件工具越出用户选择的文件夹（命令经审批兜底）。

## 3. 约束

- Windows 10/11 x64；公司分发（无代码签名证书时的 SmartScreen 提示要写进安装说明）。
- 服务端 = 用户现有部署（Docker Compose，当前 http://localhost:8080；团队使用建议 LAN/HTTPS）。
- DSH 全家桶锁 0.2.2-rc.5（与服务端一致）；本机宿主 Node ≥ 24.9（随包带运行时）。
- 桌面端随服务端版本配套发布：合同体来自服务端 kernel/wire.py，两端版本要配对
  （客户端报版本，服务端扩展可设最低版本）。
- 安装包体积目标 ≤ 300 MB（Electron + Node 运行时；不含 Office 引擎）。

## 4. 方案比较（已选定）

- **A（选定）Electron 壳 + 内嵌现有网页 + 随包 Node 本机宿主。**
  复用最大化（网页 UI、合同、通用插件层全现成），与商业版/DSH 官方桌面版同构，
  全栈 TS/JS + 一个 Python 扩展包。代价：安装包 150–250 MB。
- B Tauri（Rust + WebView2）+ Node 侧车：包体小，但主进程逻辑换 Rust、两门语言、
  WebView2 版本参差、无官方参考形态。排除。
- C 纯 CLI/托盘 + 浏览器：非技术同事分发不合适。排除。

## 5. 架构与部件

```
┌─ 员工电脑（Windows）────────────────────────────────────────┐
│ Electron 应用                                               │
│  ├─ 渲染进程：加载服务端网页（含我们的前端插槽包）            │
│  │    「本机」对话来源 / 文件夹选择 / 命令确认弹窗            │
│  ├─ preload：window 桥（插槽实现 ↔ 主进程 IPC）              │
│  └─ 主进程（TS）：                                          │
│      登录（系统浏览器 OAuth+PKCE，loopback 回调）             │
│      令牌库（safeStorage/DPAPI）+ 令牌交换（model/tools/skills）│
│      设备注册/心跳/版本上报；自动更新（electron-updater）      │
│      本机宿主子进程管理（随包 Node 24）                       │
│      命令/审批确认对话框的原生兜底                            │
│  本机宿主（Node 子进程，DSH 配置档）：                       │
│      dsh-sdk-minimal + @knowwork/dsh-host（开源通用层）       │
│      + @knowwork/desktop-host-bundle（新写环境层）：          │
│        官方本机 filesystem/subprocess（工作目录=所选文件夹）   │
│        官方 bash/文件工具/present/jobs/todo/ask-user/skill/   │
│        subagent/schedule（照服务端环境层的挂法）              │
│        审批/提问应答 → 主进程私有通道 → 渲染弹窗               │
│        模型 → 服务端公开模型网关（短期令牌）                   │
│        工具/技能 → /api/extensions/tools|skills（设备令牌）    │
│        会话事件 → 主进程 → 服务端设备事件接口                  │
└──────────────────────────────────────────────────────────────┘
        │ 全部经服务端公开端口（网关 /api）
┌─ 服务端（现有部署 + 我们的镜像派生）─────────────────────────┐
│ knowwork-server 镜像 + pip install knowwork-desktop-extension │
│  扩展（license_module=None）：                               │
│   登记 OAuth 客户端「KnowWork 桌面端」                        │
│   设备会话路由（包 ctx.device_conversations，判设备/归属）     │
│   设备注册表（迁移分支，RLS）+ 管理接口 + 审计                 │
│   更新源（安装包下载 + electron-updater feed）+ 最低版本闸门   │
│   网页会话换取（OAuth 令牌 → 网页 Cookie，供内嵌网页登录）     │
│ gateway/web 镜像重编：KNOWWORK_WEB_EXTENSIONS 指向插槽包       │
│  插槽包：本机对话来源、侧栏工作区分组、管理后台「设备」页       │
└──────────────────────────────────────────────────────────────┘
```

### 5.1 服务端扩展（Python 包 `knowwork-desktop-extension`）

- entry point `knowwork.extensions`，`license_module=None`，自带 Alembic 迁移分支。
- `setup_api(ctx)`：
  - 登记 OAuth 客户端（ctx.oauth_clients）：client_id `kw-desktop`，公开客户端 PKCE-only，
    loopback 重定向（http://127.0.0.1:*/callback）。
  - 设备会话路由（用户令牌鉴权 + 设备归属判定）：
    POST 建本机对话、GET 合同体（session/prepare_turn）、POST 事件批（push）、
    POST 逐字片段（push_live）、GET position、POST remember_approval、GET models。
    判定规则：对话归本人且 source=device；设备号来自登录 grant（ctx.oauth_device_id）。
  - 令牌交换受众接线：model 受众开源已自动登记（app.py:599）；tools/skills 受众经
    ctx.device_tokens 现成签发器登记到 ctx.oauth_exchangers，交换前判「会话归本人 + 设备有效」。
  - 设备注册表：device(id, workspace_id, user_id, name, os, app_version, last_seen,
    status, grant_id)；登录/心跳时 upsert；管理接口（空间管理员）：列表/吊销/最低版本设置。
    吊销 = ctx 侧 oauth.revoke_device + 注册表标停用；令牌交换与设备路由都查注册表。
  - 更新源：GET /api/desktop/update/latest.yml + 安装包下载（electron-updater generic
    provider）；安装包文件放对象存储（ctx.stores_for）或镜像内目录（部署时挂载）。
  - 网页会话换取：POST /api/desktop/web-session（OAuth 访问令牌 → 正常网页会话 Cookie），
    供 Electron 内嵌网页免二次登录。**机制需实现时核对 identity.sessions 的建会话路径。**
  - 审计：设备登录/吊销/强制升级经 ctx 审计 sink 记录。
- 迁移：device 表 + 设置表（最低版本等），开 RLS（照 rls.py 的函数）。
- 部署：`FROM knowwork-server:v0.1.2` + `pip install` 扩展包，compose 换 api/worker/
  model-gateway 镜像名（bootstrap 同镜像）。

### 5.2 前端插槽包（`@knowwork/desktop-web`，构建进 web 镜像）

- `install(register)`：
  - `chat.sources` 登记「本机」来源：操作（发轮/停止/审批/回答）经 preload 桥交主进程；
    文件读/存/打开/拖出经桥；工作文件夹列表与选择；访问模式控件（文件夹范围展示）。
    仅在「外壳存在」（preload 桥在）时登记——普通浏览器看不到本机入口。
  - 侧栏分组：本机对话按工作文件夹分组（插槽已预留，registry.ts:111）。
  - AdminNavEntry：管理后台「设备」页（列表/吊销/最低版本/更新包管理），调扩展接口。
- 构建：gateway 镜像重编（KNOWWORK_WEB_EXTENSIONS 指向本包入口）。**需核对
  deploy/docker/gateway.Dockerfile 的 web 构建路径与 vite 别名配置。**

### 5.3 Electron 应用（`desktop/app`）

- 主进程职责见架构图。要点：
  - 首启设置服务端地址（存本地配置）；登录走系统浏览器 → 服务端确认页 → loopback 回调；
    刷新令牌存 safeStorage；访问令牌到期自动刷新，刷新失败回登录页。
  - 设备号：首启生成 UUID 持久化（与 OAuth authorize 的 device_id 一致），设备名取机器名。
  - 令牌交换：为本机宿主换 model/tools/skills 短期令牌，经私有通道（stdio JSON-RPC 或
    本地命名管道）交给宿主，到期前轮换；**凭据只在主进程**（照 oauth_exchange.py 注释）。
  - 宿主生命周期：随应用起停；崩溃自动拉起并恢复会话（DSH 官方检查点机制）。
  - 事件上行：宿主官方事件 → 批量 POST 设备事件接口（≤500 条/批，按 seq 递增，
    断线从 position 续传）；逐字片段单独通道。
  - 更新：electron-updater generic provider 指向服务端更新源；启动检查 + 定期检查；
    低于最低版本时强制更新页。
- preload：最小化桥（invoke/on 白名单），实现前端插槽需要的能力；contextIsolation 开。
- 渲染进程：直接 loadURL(服务端地址)；先经 web-session 换取种 Cookie。
  外站链接交系统浏览器（publicOrigin.ts 已约定）。

### 5.4 本机宿主环境层（`@knowwork/desktop-host-bundle`，Node 包）

- 配置档：dsh-sdk-minimal + @knowwork/dsh-host + 本包（照 runtime-host/profile 结构）。
- 与服务端环境层（host-bundle/cordis.patch.yml）的差异：
  - **不停用**官方 filesystem/subprocess/本机 shell——执行世界就是本机；
    filesystem 工作目录 = 用户所选文件夹（每会话一个，建会话时由主进程告知）；
  - 停用 sdk-app-startup/sdk-jsonrpc-server，收件入口 = 主进程私有通道喂 intake.mjs
    同一份合同体（session_body/turn_body）；
  - 审批/提问：通用层应答者照挂，决定来自主进程（渲染弹窗；应用无窗口时原生对话框兜底）；
    「本会话不再询问」经主进程调服务端 remember_approval；
  - 模型：dsh-llm-pi-ai 指向服务端公开模型网关，apiKeyEnv 由主进程注入短期令牌；
  - 工具桥/技能提供方：指向公开 /api/extensions/tools|skills，令牌同上；
    技能环境变量 deliverEnv 打开（skills/environment.py 的 device 路径）；
  - 事件转发：官方会话事件 → 主进程（含子 Agent 事件带子会话编号）；
  - 人设/语言/时钟/检查点/压缩裁剪等照服务端环境层挂法。
- 安全口径：文件工具根在所择文件夹；**bash 命令一律审批**（policy ask，无默认放行）；
  命令确认弹窗展示完整命令与工作目录。

### 5.5 打包与分发

- electron-builder，NSIS 安装包（per-user 安装，免管理员权限）；x64。
- 随包 Node 24 运行时（宿主子进程用，不依赖用户机器装 Node）。
- 签名：本期无证书，安装说明写明 SmartScreen 提示；预留签名配置（公司证书到位即启用）。
- 更新包与 feed 由服务端扩展提供；版本号与服务端扩展版本配套。

## 5.6 已有资产复用（2026-11-25 盘点）

短暂试过的「DSH 品牌壳 + bundle」方向虽作废，其产出有可复用部分：

| 资产 | 位置 | 处置 |
|---|---|---|
| 服务端扩展（OAuth 客户端/令牌交换/下载路由） | `C:\Users\cheng\.cowork\server-extension`（22 测试，已部署本地 KnowWork） | **复用**：改 client_id/名称为 `kw-desktop`；下载路由直接用作安装包托管；新增设备会话/注册表/web-session/更新 feed |
| OAuth PKCE + 令牌刷新逻辑 | `C:\Users\cheng\.cowork\bundle\src\login.mjs`（61 测试，含 settled/dispose 竞态与超时修复） | **移植**到 Electron 主进程（TS）：回环回调校验、state timingSafeEqual、锁内刷新、AbortSignal 超时 |
| DSH/KnowWork API 笔记 | `C:\Users\cheng\.cowork\bundle\docs\api-notes.md` | **保留**：credentials/llm-pi-ai/OAuth/网关/令牌交换的确切签名与路径 |
| 贴牌流水线 | `C:\Users\cheng\.cowork\rebrand`（41 测试） | **作废**（不重打包 DSH 壳） |
| DSH bundle（knowwork-login/models） | `C:\Users\cheng\.cowork\bundle` | **作废**为 DSH 插件形态；逻辑移植，包本体不再使用 |

## 6. 里程碑（我的划分，可调整）

- **M1 端到端可用**：服务端扩展（OAuth 客户端 + 设备会话路由 + 令牌交换 + web-session）、
  Electron 壳（登录/内嵌网页/宿主管理）、环境层（文件/命令 + 文件夹范围 + 审批弹窗）、
  前端插槽包（本机来源）、事件回传。验收：本机对话跑通「读本地文件 → 生成文件 → present
  交付 → 网页端同一条对话可看」，命令先问本人。
- **M2 团队分发**：设备注册表 + 管理后台设备页 + 远程吊销 + 最低版本 + 更新源 +
  自动更新 + NSIS 安装包 + 审计接线 + 心跳。验收：两台机器装包、后台吊销其一即退回登录页。
- **M3 增强（另议）**：本机 Office 引擎（LibreOffice Kit）、流式执行/终端评估、代码签名。

## 7. 留给实现者的开放项（实现时核对，不改变本设计）

1. web-session 换取的具体建会话路径（identity/sessions.py）与 Cookie 属性（SameSite/CSRF）。
2. chat.sources 插槽的完整接口形状（sources.ts 全文）与 preload 桥的最小面。
3. intake.mjs 私有通道喂合同的确切入口（本机宿主收件逻辑的函数签名）。
4. gateway.Dockerfile 的 web 构建方式与 KNOWWORK_WEB_EXTENSIONS 的接线细节。
5. electron-updater generic provider 的 feed 布局（latest.yml 字段）。
6. 官方 bash 工具在 Windows 的 shell 选择（pwsh/cmd）与审批卡片展示。
7. 设备心跳频率与 last_seen 精度（建议 5 分钟，管理页「最近活跃」按此展示）。
8. DSH 官方桌面版（@deepseek-ai/dsh  npm 包内）可参考的主进程/宿主通道范式。

## 8. 我的决定（默认值，评审可否决）

- 代码组织：全部放用户 fork（D:\AI\knowwork）新目录 `desktop/`
  （server-extension / app / host-bundle / web-extension 四包），不动现有目录。
- 文件夹范围：每段本机对话选一个工作文件夹；文件工具根在其中；命令审批兜底。
- 设备管理页权限：空间管理员（开源单空间）；系统级视图后续再说。
- 安装包：per-user NSIS，无签名先行；更新源走服务端对象存储。
- 心跳 5 分钟；刷新令牌沿用开源 30 天闲置策略。
- M1 不含本机 Office 生成（技能清单里需要本地引擎的技能在本机对话中不可见/明示原因）。