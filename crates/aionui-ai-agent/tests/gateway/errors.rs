use std::time::Duration;

use aion_types::llm::LlmEvent;
use aionui_ai_agent::manager::aionrs::providers::{GatewayConfig, create_provider};

use super::support::*;

#[tokio::test]
async fn sdk_rejects_truncated_malformed_and_empty_streams() {
    let partial = "data:{\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n";
    for (wire, count, expected) in [
        (String::new(), 3, "without a terminal event"),
        ("data:[DONE]\n\n".into(), 3, "without a finish reason"),
        (
            format!("{partial}data:{{invalid}}\n\n"),
            1,
            "Invalid JSON in OpenAI SSE event",
        ),
        (format!("{partial}data:{{\"choices\":[]}}"), 1, "inside an SSE event"),
        (partial.into(), 1, "without a terminal event"),
    ] {
        let server = server(vec![(wire.into_bytes(), vec![]); count], 3).await;
        let provider = create_provider(&config(&server.url), Some(&GatewayConfig::default())).unwrap();
        let mut rx = provider.stream(&request()).await.unwrap();
        let mut failed = false;
        while let Some(event) = tokio::time::timeout(Duration::from_secs(5), rx.recv()).await.unwrap() {
            match event {
                LlmEvent::TextDelta(_) => {}
                LlmEvent::Error(message) => {
                    assert!(message.contains(expected), "{message}");
                    failed = true;
                }
                other => panic!("failure must not produce a successful event: {other:?}"),
            }
        }
        assert!(failed);
    }
}

#[tokio::test]
async fn sdk_http_errors_retain_status_and_redact_configured_credentials() {
    use aion_providers::ProviderError;
    for status in [301, 400, 401, 403, 429] {
        let mut server = http_server(
            vec![(b"synthetic-key synthetic-secret".to_vec(), vec![])],
            4096,
            status,
            "application/json",
        )
        .await;
        let gateway = GatewayConfig {
            headers: vec![("X-Key".into(), "synthetic-secret".into())],
            ..Default::default()
        };
        let provider = create_provider(&config(&server.url), Some(&gateway)).unwrap();
        let error = provider.stream(&request()).await.unwrap_err();
        assert!(!error.to_string().contains("synthetic-key"));
        assert!(!error.to_string().contains("synthetic-secret"));
        if status == 429 {
            assert!(matches!(error, ProviderError::RateLimited { .. }));
        } else {
            assert!(matches!(error, ProviderError::Api { status: actual, .. } if actual == status));
        }
        assert!(server.requests.recv().await.is_some());
    }
}
