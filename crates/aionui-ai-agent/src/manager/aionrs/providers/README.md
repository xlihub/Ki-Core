# Ki-Core 的 Ki-Model SDK 集成

对应 [Ki-Core #21](https://github.com/xlihub/Ki-Core/issues/21)。Core 只负责配置、凭据和 HTTP client 装配，以及 Agent 注入。消息转换、SSE 分帧、工具协议和流事件由 Ki-Model 的 `OpenAIProvider` 处理，Core 没有独立 `LlmProvider` 实现。

## 创建和配置契约

`create_provider(&Config, Option<&GatewayConfig>)` 是聊天、新会话、恢复和健康检查共用入口。没有高级配置时调用 SDK 原有 `aion_providers::create_provider`；有配置时调用 `OpenAIProvider::with_options`，要求已有 provider family 为 OpenAI、API mode 为 Chat Completions。配置不根据客户名称、地址或模型名称选择协议。

调用方在 `AionrsResolvedConfig.compat_overrides.gateway` 传入可选配置。`GatewayConfig` 可通过 serde 序列化，不包含 client、闭包或运行时对象。字段如下：

| 字段 | 默认值与含义 |
| --- | --- |
| `auth` | `bearer`；`none` 时 SDK 不生成 Bearer，允许 API key 为空 |
| `headers` | 名称/值二元组列表；保留重复输入交给 SDK 校验，不能存放 client 隐式鉴权 |
| `include_stream_options` | 未设置时保留已有 compat；false 时不发送 `stream_options` |
| `connect_timeout_ms` | 未设置为 10000；显式设置必须大于零 |
| `read_timeout_ms` | 未设置为 30000；每次网络读取等待上限，显式设置必须大于零 |
| `request_timeout_ms` | 未设置时无总请求上限；显式设置必须大于零 |

`api_key`、`base_url`、`model` 及 `compat_overrides.api_path`、`max_tokens_field` 继续使用已有字段。`api_path = Some("")` 表示完整 URL，保留查询参数和末尾斜线；否则由 SDK 拼接路径。其余 SDK `ProviderCompat` 原样传递。Core 构造 client 时禁用重定向和 reqwest 底层重试，保留系统代理及 TLS 策略；SDK 自身的有限重试仍按 SDK 契约执行，已输出内容后不得重放。

后续配置/凭据工单负责 API schema、保存与校验、加密、解密和权限。当前 gateway 字段承载已解析数据；附加头值必须视为凭据，不能直接放入公共设置或日志。`GatewayConfig::Debug` 仅显示鉴权模式、头数量和网络选项，不显示头名或值。

## 错误和 Agent 结果

`GatewayCreationError` 区分 provider family 冲突、Responses mode 冲突、零超时、HTTP client 构造失败及 SDK `OpenAIConfigError`。SDK 错误保留缺失/非法 key、非法头名/值、重复头、Authorization 冲突和保留头的类型与输入索引，不回显输入值。当前 Agent 入口将构造错误映射到现有 `AgentError`，没有新增 HTTP endpoint。

HTTP 请求与流错误遵循 SDK `ProviderError`。SDK 会脱敏已配置 key 和附加头值，但不承诺删除任意服务端响应正文。Core 不解析原始 SSE，也不重新实现消息或事件转换。

SDK 可能在触发轮次上限时返回空文本和 `Ok(AgentResult)`。Core 将模型调用后的空答案和非 `EndTurn` 结果视为失败，避免返回成功或继续发出 `Finish`。成功本地命令返回 `turns=0`、空文本和 `EndTurn`，保留其原有语义。`OutputSink::emit_error` 也用于可继续执行的诊断，Core 不用它推断 Agent 的结束状态。健康检查保留 16 token、单次计数轮次和 30 秒总预算，并检查结果内容与结束状态。用户取消仍按已有停止语义结束界面流，不表示模型成功回答。

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
