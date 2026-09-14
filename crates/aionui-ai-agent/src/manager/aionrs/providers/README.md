# Ki-Core 的 Ki-Model SDK 集成

对应 [Ki-Core #21](https://github.com/xlihub/Ki-Core/issues/21)。Core 只负责配置、凭据和 HTTP client 装配，以及 Agent 注入。消息转换、SSE 分帧、工具协议和流事件由 Ki-Model 的 `OpenAIProvider` 处理，Core 没有独立 `LlmProvider` 实现。

## 创建和配置契约

`create_provider(&Config, Option<&GatewayConfig>)` 是聊天、新会话、恢复和健康检查共用入口。没有高级配置时调用 SDK 原有 `aion_providers::create_provider`；有配置时调用 `OpenAIProvider::with_options`，要求已有 provider family 为 OpenAI、API mode 为 Chat Completions。配置不根据客户名称、地址或模型名称选择协议。

调用方在 `AionrsResolvedConfig.compat_overrides.gateway` 传入可选配置。`GatewayConfig` 可通过 serde 序列化，不包含 client、闭包或运行时对象。字段如下：

| 字段 | 默认值与含义 |
| --- | --- |
| `auth` | `bearer`；`none` 时 SDK 不生成 Bearer，允许 API key 为空 |
| `headers` | 名称/值二元组列表；保留重复输入交给 SDK 校验，不能存放 client 隐式鉴权 |
| `proxy` | `default` 保留 reqwest 默认代理发现；`direct` 对当前 client 调用 `no_proxy()` |
| `include_stream_options` | 未设置时保留已有 compat；false 时不发送 `stream_options` |
| `connect_timeout_ms` | 未设置为 10000；范围 1–300000 毫秒 |
| `read_timeout_ms` | 未设置为 30000；每次网络读取等待上限，范围 1–3600000 毫秒 |
| `request_timeout_ms` | 未设置时无总请求上限；范围 1–3600000 毫秒 |

`api_key`、`base_url`、`model` 及 `compat_overrides.api_path`、`max_tokens_field` 继续使用已有字段。`api_path = Some("")` 表示完整 URL，保留查询参数和末尾斜线；否则由 SDK 拼接路径。其余 SDK `ProviderCompat` 原样传递。Core 构造 client 时禁用重定向和 reqwest 底层重试，按连接选择默认代理发现或直连，并保留 TLS 策略；SDK 自身的有限重试仍按 SDK 契约执行，已输出内容后不得重放。

API 与持久化契约见下节。运行时 gateway 字段只承载从当前用户 provider 记录解析的数据；附加头值必须视为凭据，不能直接放入公共设置或日志。`GatewayConfig::Debug` 仅显示鉴权模式、头数量和网络选项，不显示头名或值。

## 错误和 Agent 结果

`GatewayCreationError` 区分 provider family 冲突、Responses mode 冲突、零超时、HTTP client 构造失败及 SDK `OpenAIConfigError`。SDK 错误保留缺失/非法 key、非法头名/值、重复头、Authorization 冲突和保留头的类型与输入索引，不回显输入值。当前 Agent 入口将构造错误映射到现有 `AgentError`，没有新增 HTTP endpoint。

HTTP 请求与流错误遵循 SDK `ProviderError`。SDK 会脱敏已配置 key 和附加头值，但不承诺删除任意服务端响应正文。Core 不解析原始 SSE，也不重新实现消息或事件转换。

SDK 可能在触发轮次上限时返回空文本和 `Ok(AgentResult)`。Core 将模型调用后的空答案和非 `EndTurn` 结果视为失败，避免返回成功或继续发出 `Finish`。成功本地命令返回 `turns=0`、空文本和 `EndTurn`，保留其原有语义。`OutputSink::emit_error` 也用于可继续执行的诊断，Core 不用它推断 Agent 的结束状态。健康检查保留 16 token 和单次计数轮次，并检查结果内容与结束状态。没有 gateway 时保留 30 秒预算；有 gateway 时使用该连接的 HTTP 超时策略，不额外套用固定 30 秒限制。用户取消仍按已有停止语义结束界面流，不表示模型成功回答。

## 依赖与发布来源

依赖记录在根目录 `ki-core-model.json`。已采用 [Ki-Model 0.1.1 正式 Release](https://github.com/xlihub/Ki-Model/releases/tag/ki-model-v0.1.1)，tag `ki-model-v0.1.1` 的 commit 为 `6e9a710738fac4e76d03d936c0c69d26cec96157`，`releaseVerified=true`。2026-09-14 已核对 tag、来源清单、SDK 源码包与六个平台资产的 SHA-256；[三系统 CI](https://github.com/xlihub/Ki-Model/actions/runs/34801180884) 和 [六平台发布构建](https://github.com/xlihub/Ki-Model/actions/runs/34801256488) 均通过。

六个直接 `aion-*` crate 引用同一固定 Git revision，`Cargo.lock` 中 SDK 间接 crate 使用同一来源。SDK package version 保留 `0.2.11`，不改成 Ki-Model 产品版本 `0.1.1`。该 commit 的 `ki-model-upstream.json` 指向 `iOfficeAI/aionrs` 的 `v0.2.11`，peeled commit 为 `8e61a90329fa9f67c4fdf7e97fe02c24dba33f75`。

后续 SDK 更新仍须在面向 `product/main` 的 PR 中核对 tag peeled commit、Release 资产和 checksum、来源清单、上游映射及跨平台检查，再更新 pin、lock 和来源记录并重新验证。`releaseVerified` 只是本次人工核验记录，不是自动发现或自动采用最新 SDK 的开关。Core 自有版本、CHANGELOG、AionCore 映射和 Release Please 节奏保持独立。

0.1.1 仍存在连续空回答最终返回 `EndTurn` 成功的问题，复现与预期错误契约见 [Ki-Model #11](https://github.com/xlihub/Ki-Model/issues/11)。该问题作为 SDK 后续修复项独立跟踪，不阻碍当前 Core 开发；Core 不按 SDK 提示文案推断失败，也不复制 SDK 状态机。

`validate-model-pin.py` 校验六个 manifest 引用、锁文件来源、重复 SDK 类型、上游版本保留和本机 patch/replace；CI 与 `just push` 执行该检查。正式发布流程额外要求 `--require-release`。上游同步后的 PR 必须继续通过检查，不能把已采用的 Ki-Model pin 改回 aionrs。原 `update-aionrs` 脚本检测到产品 pin 后拒绝自动更新。

## 验证入口

```bash
cargo test -p aionui-ai-agent --test gateway_provider --locked
python3 scripts/ki-core-release/validate-model-pin.test.py
python3 scripts/ki-core-release/validate-model-pin.py
```

集成测试只使用临时目录、本机随机端口、合成模型和凭据。覆盖真实 Core Agent 的自定义完整 URL、Bearer 与仅头鉴权、首文本时序、内置 Read 执行、tool_call_id 与 opaque metadata 回传、后续回答和恢复；同时覆盖健康检查、空结果、错误脱敏、截断/空流、取消、读取超时和输出后不重放。无高级配置与显式默认 options 的请求/事件兼容性单独比较。SSE 的合法 EOF、工具 schema 等细节服从 SDK 契约，不继承已废除的 Core 自定义实现规则。

已核对的 SDK 依据（相对于 Ki-Model 仓库）：`docs/ki-model/openai-gateway.md`、`crates/aion-providers/src/openai.rs`、`openai_options.rs`、`provider.rs`、`stream_process.rs`、`stream_runner.rs`、`transport.rs`，以及 `crates/aion-agent/src/engine.rs` 和 `output/sink.rs`。


## Provider API 与桌面消费契约（#22–#25）

沿用 `/api/providers` 的 POST/GET 与 `/api/providers/{id}` 的 PUT/DELETE、现有用户隔离、认证及 CSRF 保护。没有新增客户或协议入口。类型位于 `aionui-api-types/src/provider_gateway.rs` 和 `provider.rs`。

| 字段 | 创建 / 读取 | 更新与兼容语义 |
| --- | --- | --- |
| `model_mode` | `automatic`（默认）或 `manual` | 不传保留；开启 gateway 不改变 mode |
| `base_url`、`models`、`is_full_url` | 复用既有字段 | manual 要求 custom/openai、HTTP(S) 完整地址、`is_full_url=true` 与非空模型 ID；运行时保留地址和请求模型，拒绝未配置模型 |
| `gateway` | 可选；缺失/null 保留旧 SDK 默认路径；`{}` 显式采用下方 gateway 默认值 | 不传/null 保留；提供对象替换整个非敏感配置（不是递归合并） |
| `gateway.auth` | `bearer` 默认，凭据仅来自现有加密 API Key；`none` 不附加 Bearer，API Key 可不传或为空 | 开启 Bearer 必须提供有效 API Key；自定义 Authorization 与 Bearer 大小写不敏感地判冲突 |
| `gateway.headers` | 任意头名数组，每项为 `name`、普通值 `value` 或 `sensitive=true` | 整个数组替换；删除条目会删除其凭据；重复头、传输保留头、非法名称/值报 400 |
| `header_credentials` | 仅写请求使用，key 为大小写不敏感的头名 | 不传保留；`{action:keep}` 保留已有值；`{action:replace,value:...}` 替换；`{action:clear}` 清除 |
| `gateway.headers[].configured` | 服务端计算的只读布尔值；敏感头不返回 value | 输入不参与凭据判断，不把星号或圆点掩码写成真实凭据 |
| `gateway.include_stream_options` | null 继承 SDK compat；false 不发送；true 发送 `include_usage:true` | 由 SDK 请求投影处理，Core 不拼请求 JSON |
| `clear_gateway` | 仅 PUT 使用 | true 清除 gateway 和新增凭据，恢复旧 Bearer 行为；要求已有/同时提供 API Key；与 gateway/凭据修改冲突时报 400 |

`gateway` 和 manual 只适用于 Chat Completions；与 Responses 或其他模型协议配置冲突时报 400。普通连接仍沿用原有自动发现。manual 的保存、编辑及按 ID 获取模型不做探测；`POST /api/providers/{id}/models` 返回已有 models，不重复存储静态模型。创建前的 `/fetch-models` 请求带 `model_mode:manual` 时返回该请求中的 models；`/detect-protocol` 带同一 mode 时明确返回 400，均不联网。

写入示例（所有值为合成数据）：

```json
{
  "platform": "custom",
  "name": "Local gateway",
  "base_url": "http://127.0.0.1:9000/custom/invoke/",
  "model_mode": "manual",
  "models": ["synthetic-model"],
  "is_full_url": true,
  "gateway": {
    "auth": "none",
    "proxy": "direct",
    "include_stream_options": false,
    "headers": [
      {"name": "X-Tenant", "value": "synthetic-tenant"},
      {"name": "X-Secret", "sensitive": true}
    ]
  },
  "header_credentials": {
    "X-Secret": {"action": "replace", "value": "synthetic-secret"}
  }
}
```

新增敏感头声明时必须同时写入凭据，或显式 clear 保存为未配置状态。clear 后该头的 configured=false，聊天/恢复/健康检查在联网前报缺失凭据；名称等普通保存不误删凭据。替换验证和加密在数据库写入前完成；失败不更新记录。凭据按 AES-256-GCM 加密为独立列，公开 gateway JSON 只存元数据与普通值。解密失败明确报错、不回显密文；可用 clear_gateway 恢复。现有 API Key 继续采用原有加密及读写兼容语义（旧 API 明文返回约定未改变）。

migration 043 为已有连接设置 automatic、gateway/凭据为空，不重写历史 migration。其他基础 DTO/row 初始化位置只添加默认值。

## 网络策略、结果和观测

所有超时单位都是毫秒。gateway 初始值为 connect=10000、read=30000、request=null。connect 范围 1–300000，覆盖建立连接（模拟 TLS 握手停滞已验证）；read 范围 1–3600000，每次网络读取重新计时；request 范围 1–3600000，覆盖一次 HTTP 尝试从连接至响应体结束，不是完整多轮 Agent 任务预算。SDK 有界重试仍可能使总耗时超过单次 request 预算。聊天与健康检查都由同一 resolver 和 create_provider 解析并创建 client。

`default` 使用当前 reqwest 构建的默认代理发现，不承诺所有操作系统代理来源均可用；`direct` 禁用当前 client 的代理。没有修改进程环境或全局 client。依赖依据是 reqwest 0.12.28 的 `ClientBuilder::no_proxy/connect_timeout/read_timeout/timeout`；实际环境代理行为由测试子进程分别设置 HTTP_PROXY/NO_PROXY 验证，避免影响其他测试。Windows 的系统代理、PAC、WinHTTP/WinINET 等来源仍需目标机器验证，桌面文案不能将 default 描述为“支持所有系统代理”。

健康检查新增 `first_event_ms`（开始检查至 SDK 首次输出文本、reasoning 或工具事件，包含 bootstrap 时间），`slow_first_event`（>=10000ms）。慢首事件可同时为 healthy；取消、超时、中断、空结果和 HTTP 错误分别使用 error_kind。服务调用方可通过 `health_check_with_cancellation` 的 CancellationToken 取得 cancelled；HTTP 调用被丢弃时记录取消并释放检查 future，已断开的客户端不会收到响应。

Core INFO 日志记录 provider/model、只含 origin 的 endpoint（不含路径/查询参数）、代理/超时策略、首输出耗时、结束状态与 usage。HTTP 错误状态通过健康结果和现有 SDK 日志提供；SDK 正常流 HTTP 状态摘要在 DEBUG、异常摘要在 WARN。所有新增日志不输出提示词、工具内容、API Key 或新增凭据。SDK 负责已配置鉴权值的错误脱敏。

### 未完成的验收项

- Windows 目标环境未验证。macOS 的受控代理测试和跨平台可编译源码不能替代此项。
- Ki-Model 0.1.1 `crates/aion-providers/src/stream_process.rs` 在 body read 失败时调用 `e.without_url().to_string()`，丢失 reqwest `is_timeout()`。因此已开始的流读取超时目前会停止请求并报告 interrupted，不能可靠地细分为 timeout；不能根据耗时猜测错误类型。握手/首响应等待阶段保留 typed error，能够报告 timeout，并给出 connect 或 request_or_read。精确区分 body read 超时需要正式 SDK 扩展后再升级固定 pin。现有测试明确记录这一限制。
- 加密函数失败已采用写入前返回路径；生产构造器固定接受 32-byte key，尚未通过 API 注入 OS RNG/AES 加密故障。已验证密文不含明文、重开数据库复用、损坏密文报错以及失败更新不改写记录。

## 本次验证入口

```bash
cargo test -p aionui-system --test provider_routes --locked
cargo test -p aionui-db --test provider_model_settings_migration --locked
cargo test -p aionui-ai-agent --test factory_provider_integration --locked
cargo test -p aionui-ai-agent --test gateway_provider --locked
cargo test -p aionui-app --test agent_provider_health_e2e --locked
cargo check --workspace --tests --locked
cargo clippy --workspace --tests --locked -- -D warnings
cargo test --workspace --locked
```

新测试覆盖 API 到已保存配置再到真实 HTTP 请求、真实 factory 新建/恢复、Bearer 与多个头并存及切换、stream_options 更新、31 秒首事件、握手/请求/流空闲策略、取消、截断、鉴权失败与脱敏、用户隔离、磁盘数据库重开及旧迁移兼容。健康检查完整 HTTP 路由测试复用现有认证/CSRF 测试组。
