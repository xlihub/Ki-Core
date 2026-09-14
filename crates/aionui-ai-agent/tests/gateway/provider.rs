mod errors;
mod options;
mod support;

use aion_types::llm::LlmEvent;
use aionui_ai_agent::manager::aionrs::providers::{GatewayConfig, create_provider};
use support::*;

#[tokio::test]
async fn text_is_observable_before_response_finishes() {
    let head = ":keep-alive\r\n\r\ndata:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\"}}]}\r\n\r\n";
    let mut server = server(vec![(head.as_bytes().to_vec(), finished())], 1).await;
    let provider = create_provider(&config(&server.url), Some(&GatewayConfig::default())).unwrap();
    let mut rx = provider.stream(&request()).await.unwrap();
    assert!(matches!(event(&mut rx).await, LlmEvent::TextDelta(text) if text == "你好"));
    let body = server.requests.recv().await.unwrap();
    assert_eq!(body["model"], "synthetic-model");
    assert_eq!(
        body["messages"][0],
        serde_json::json!({"role":"system", "content":"Synthetic system"})
    );
    assert_eq!(
        body["messages"][1],
        serde_json::json!({"role":"user", "content":"Hello"})
    );
    assert_eq!(body["stream"], true);
    server.release.send(()).await.unwrap();
    assert!(matches!(event(&mut rx).await, LlmEvent::Done { .. }));
    assert!(rx.recv().await.is_none());
}

#[tokio::test]
async fn native_tool_history_and_definitions_reach_the_gateway() {
    use aion_types::{
        message::{ContentBlock, Message, Role},
        tool::ToolDef,
    };
    use serde_json::json;
    let mut server = server(
        vec![(
            b"data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"}}]}\n\n".to_vec(),
            finished(),
        )],
        4096,
    )
    .await;
    let provider = create_provider(&config(&server.url), Some(&GatewayConfig::default())).unwrap();
    let mut req = request();
    req.tools.push(ToolDef {
        name: "Read".into(),
        description: "Read a file".into(),
        input_schema: json!({"type":"object"}),
        deferred: false,
    });
    req.messages.push(Message::new(
        Role::Assistant,
        vec![
            ContentBlock::Thinking {
                thinking: "inspect".into(),
                signature: None,
            },
            ContentBlock::Text { text: "Reading".into() },
            ContentBlock::ToolUse {
                id: "call-1".into(),
                name: "Read".into(),
                input: json!({"file_path":"/synthetic/file"}),
                extra: None,
            },
        ],
    ));
    req.messages.push(Message::new(
        Role::Tool,
        vec![ContentBlock::ToolResult {
            tool_use_id: "call-1".into(),
            content: "synthetic result".into(),
            is_error: false,
        }],
    ));
    req.messages.push(Message::new(
        Role::User,
        vec![ContentBlock::Text {
            text: "Continue".into(),
        }],
    ));
    let mut rx = provider.stream(&req).await.unwrap();
    let body = server.requests.recv().await.unwrap();
    assert_eq!(
        body["tools"],
        json!([{"type":"function","function":{"name":"Read","description":"Read a file","parameters":{"type":"object","properties":{},"$schema":"https://json-schema.org/draft/2020-12/schema"}}}])
    );
    assert_eq!(
        body["messages"][2],
        json!({"role":"assistant", "content":"Reading", "reasoning_content":"inspect", "tool_calls":[{"id":"call-1","type":"function","function":{"name":"Read","arguments":"{\"file_path\":\"/synthetic/file\"}"}}]})
    );
    assert_eq!(
        body["messages"][3],
        json!({"role":"tool", "tool_call_id":"call-1", "content":"synthetic result"})
    );
    assert_eq!(body["messages"][4], json!({"role":"user", "content":"Continue"}));
    server.release.send(()).await.unwrap();
    while rx.recv().await.is_some() {}
}

#[tokio::test]
async fn bytewise_and_chunked_tools_reasoning_and_usage() {
    use serde_json::json;
    let wire = concat!(
        "\u{feff}: comment\r\n\r\ndata:{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"思考\"}}]}\r\n\r\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"Read\",\"arguments\":\"{\\\"file_\"}}]}}]}\n\n",
        "data:{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"path\\\":\\\"文件\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
        "data:{\"choices\":[],\n",
        "data: \"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7,\"prompt_tokens_details\":{\"cached_tokens\":3}}}\n\n",
        "data:[DONE]\n\n",
    );
    for fragment in [1, 2, 3, 7, 64, wire.len()] {
        let server = server(vec![(wire.as_bytes().to_vec(), vec![])], fragment).await;
        let provider = create_provider(&config(&server.url), Some(&GatewayConfig::default())).unwrap();
        let mut rx = provider.stream(&request()).await.unwrap();
        assert!(matches!(event(&mut rx).await, LlmEvent::ThinkingDelta(text) if text == "思考"));
        assert!(
            matches!(event(&mut rx).await, LlmEvent::ToolUse {id, name, input, extra: None} if id == "call-1" && name == "Read" && input == json!({"file_path":"文件"}))
        );
        assert!(
            matches!(event(&mut rx).await, LlmEvent::Done {stop_reason: aion_types::message::StopReason::ToolUse, usage} if usage.input_tokens == 11 && usage.output_tokens == 7 && usage.cache_read_tokens == 3)
        );
        assert!(rx.recv().await.is_none());
    }
}

mod agent;

#[tokio::test]
async fn dropping_receiver_closes_network_without_waiting_for_response() {
    let mut server = server(vec![(vec![], b"pending".to_vec())], 1).await;
    let provider = create_provider(&config(&server.url), Some(&GatewayConfig::default())).unwrap();
    let rx = provider.stream(&request()).await.unwrap();
    server.requests.recv().await.unwrap();
    drop(rx);
    tokio::time::timeout(std::time::Duration::from_secs(2), server.disconnected.recv())
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn explicit_max_token_field_is_applied() {
    let mut server = server(
        vec![(
            b"data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"}}]}\n\n".to_vec(),
            finished(),
        )],
        1,
    )
    .await;
    let mut cfg = config(&server.url);
    cfg.compat.transport.max_tokens_field = Some("max_completion_tokens".into());
    let provider = create_provider(&cfg, Some(&GatewayConfig::default())).unwrap();
    let mut rx = provider.stream(&request()).await.unwrap();
    let body = server.requests.recv().await.unwrap();
    assert_eq!(body["max_completion_tokens"], 32);
    assert!(body.get("max_tokens").is_none());
    server.release.send(()).await.unwrap();
    while rx.recv().await.is_some() {}
}

#[tokio::test]
async fn standard_provider_retains_sdk_chat_completions_behavior() {
    let mut wire = b"data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"standard\"}}]}\n\n".to_vec();
    wire.extend(b"data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n");
    let mut server = server(vec![(wire, vec![])], 4096).await;
    let provider = create_provider(&config(&server.url), None).unwrap();
    let mut rx = provider.stream(&request()).await.unwrap();
    assert!(matches!(event(&mut rx).await, LlmEvent::TextDelta(text) if text == "standard"));
    assert!(matches!(event(&mut rx).await, LlmEvent::Done { .. }));
    assert_eq!(server.requests.recv().await.unwrap()["model"], "synthetic-model");
}

#[test]
fn conflicting_protocol_configuration_is_rejected_explicitly() {
    let mut cfg = config("http://127.0.0.1:1/chat/completions");
    cfg.compat.transport.openai_api_mode = Some(aion_config::compat::OpenAiApiMode::Responses);
    assert!(matches!(
        create_provider(&cfg, Some(&GatewayConfig::default())),
        Err(aionui_ai_agent::manager::aionrs::providers::GatewayCreationError::UnsupportedApiMode)
    ));
    cfg.compat.transport.openai_api_mode = None;
    cfg.provider = aion_config::config::ProviderType::Anthropic;
    assert!(matches!(
        create_provider(&cfg, Some(&GatewayConfig::default())),
        Err(aionui_ai_agent::manager::aionrs::providers::GatewayCreationError::UnsupportedProvider)
    ));
}

mod compatibility;
