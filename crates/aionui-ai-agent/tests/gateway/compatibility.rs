use super::support::*;
use aion_types::{
    llm::{LlmEvent, LlmRequest},
    message::{ContentBlock, Message, Role},
    tool::ToolDef,
};
use aionui_ai_agent::manager::aionrs::providers::{GatewayConfig, create_provider};
use serde_json::{Value, json};

async fn exchange(
    gateway: Option<&GatewayConfig>,
    request: &LlmRequest,
    wire: &[u8],
    configure: impl FnOnce(&mut aion_config::config::Config),
) -> (Value, Vec<Value>) {
    let mut server = server(vec![(wire.to_vec(), vec![])], 4096).await;
    let mut cfg = config(&server.url);
    configure(&mut cfg);
    let provider = create_provider(&cfg, gateway).unwrap();
    let mut rx = provider.stream(request).await.unwrap();
    let mut events = Vec::new();
    while let Some(event) = rx.recv().await {
        events.push(match event {
            LlmEvent::TextDelta(text) => json!({"text":text}),
            LlmEvent::ThinkingDelta(text) => json!({"reasoning":text}),
            LlmEvent::ToolUse { id, name, input, extra } => {
                json!({"tool": {"id":id,"name":name,"input":input,"extra":extra}})
            }
            LlmEvent::Done { stop_reason, usage } => json!({"done":format!("{stop_reason:?}"),"usage":usage}),
            other => panic!("unexpected provider event: {other:?}"),
        });
    }
    (server.requests.recv().await.unwrap(), events)
}

fn success_wire() -> Vec<u8> {
    b"data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        .to_vec()
}

#[tokio::test]
async fn requests_match_sdk_for_text_tools_and_gateway_compat() {
    let mut req = request();
    req.max_tokens = None;
    req.reasoning_effort = Some("high".into());
    req.messages = vec![Message::new(
        Role::User,
        vec![
            ContentBlock::Text {
                text: "line one".into(),
            },
            ContentBlock::Text {
                text: "line two".into(),
            },
        ],
    )];
    req.tools = vec![
        ToolDef {
            name: "Read".into(),
            description: "Read a file".into(),
            input_schema: json!({"type":"object"}),
            deferred: false,
        },
        ToolDef {
            name: "DeferredSearch".into(),
            description: "Search data\n\nDetailed instructions".into(),
            input_schema: json!({"type":"object","properties":{"query":{"type":"string"}}}),
            deferred: true,
        },
    ];
    let configure = |cfg: &mut aion_config::config::Config| {
        cfg.compat.transport.default_max_tokens = Some(1234);
        cfg.compat.transport.include_stream_options = Some(false);
        cfg.compat.reasoning.supports_effort = Some(false);
    };
    let standard = exchange(None, &req, &success_wire(), configure).await;
    let gateway = exchange(Some(&GatewayConfig::default()), &req, &success_wire(), configure).await;
    assert_eq!(gateway, standard);
}

#[tokio::test]
async fn images_assistant_history_and_tool_metadata_match_sdk() {
    use aion_types::message::ImageUrl;
    let mut req = request();
    req.messages.push(Message::new(
        Role::Assistant,
        vec![
            ContentBlock::Thinking {
                thinking: "inspect".into(),
                signature: None,
            },
            ContentBlock::Text { text: "Reading".into() },
        ],
    ));
    req.messages.push(Message::new(
        Role::Assistant,
        vec![ContentBlock::ToolUse {
            id: "call-1".into(),
            name: "Read".into(),
            input: json!({"file_path":"/synthetic"}),
            extra: Some(json!({"opaque":"synthetic"})),
        }],
    ));
    req.messages.push(Message::new(
        Role::User,
        vec![ContentBlock::ToolResult {
            tool_use_id: "call-1".into(),
            content: "result".into(),
            is_error: false,
        }],
    ));
    req.messages.push(Message::new(
        Role::User,
        vec![
            ContentBlock::Text {
                text: "inspect image".into(),
            },
            ContentBlock::Image {
                image_url: ImageUrl {
                    url: "data:image/png;base64,AAAA".into(),
                },
            },
        ],
    ));
    req.thinking = Some(aion_types::llm::ThinkingConfig::Disabled);
    let standard = exchange(None, &req, &success_wire(), |_| {}).await;
    let gateway = exchange(Some(&GatewayConfig::default()), &req, &success_wire(), |_| {}).await;
    assert_eq!(gateway, standard);
}

#[tokio::test]
async fn reasoning_repeated_tool_names_metadata_and_usage_match_sdk() {
    let chunks = [
        json!({"choices":[{"index":0,"delta":{"reasoning_content":"","reasoning":"思考","content":"answer"}}]}),
        json!({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"Read","arguments":"{\"file_path\":"},"extra_content":{"opaque":"synthetic"}}]}}]}),
        json!({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"Read","arguments":"\"file\"}"}}]},"finish_reason":"stop"}]}),
        json!({"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"cached_tokens":3}}),
    ];
    let mut wire = chunks.iter().map(|v| format!("data: {v}\n\n")).collect::<String>();
    wire.push_str("data: [DONE]\n\n");
    let standard = exchange(None, &request(), wire.as_bytes(), |_| {}).await;
    let gateway = exchange(Some(&GatewayConfig::default()), &request(), wire.as_bytes(), |_| {}).await;
    assert_eq!(gateway, standard);
}
