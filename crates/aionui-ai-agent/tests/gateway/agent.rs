use super::support::*;
use aionui_ai_agent::{
    AgentStreamEvent, IAgentTask,
    manager::aionrs::{
        AionrsAgentManager,
        providers::{GatewayAuth, GatewayConfig},
    },
    types::{AionrsResolvedConfig, SendMessageData},
};
use serde_json::json;
use std::{collections::HashMap, sync::Arc, time::Duration};

fn resolved(url: &str, directory: &std::path::Path) -> AionrsResolvedConfig {
    let mut compat = aionui_ai_agent::types::AionrsCompatOverrides::default();
    compat.gateway = Some(GatewayConfig {
        headers: vec![("X-Synthetic-Key".into(), "synthetic-secret".into())],
        ..Default::default()
    });
    compat.api_path = Some(String::new());
    AionrsResolvedConfig {
        provider: "openai".into(),
        api_key: "synthetic-key".into(),
        model: "synthetic-model".into(),
        base_url: Some(url.into()),
        system_prompt: Some("Synthetic system".into()),
        max_tokens: None,
        max_turns: Some(4),
        max_tool_call_malformed_turns: Some(1),
        max_tool_call_failure_turns: Some(1),
        compat_overrides: compat,
        session_directory: directory.join("sessions"),
        session_mode: Some("yolo".into()),
        skills: vec![],
        extra_mcp_servers: HashMap::new(),
        bedrock_config: None,
        runtime_env: vec![],
        prompt_dump_dir: None,
    }
}

fn message(text: &str) -> SendMessageData {
    SendMessageData {
        content: text.into(),
        msg_id: "synthetic-msg".into(),
        turn_id: Some("synthetic-turn".into()),
        files: vec![],
        inject_skills: vec![],
    }
}

#[tokio::test]
async fn local_slash_commands_succeed_without_a_model_answer() {
    let dir = tempfile::tempdir().unwrap();
    let server = server(vec![], 4096).await;
    let agent = AionrsAgentManager::new(
        "command-session".into(),
        dir.path().to_string_lossy().into_owned(),
        resolved(&server.url, dir.path()),
        None,
    )
    .await
    .unwrap();
    agent.send_message(message("/clear")).await.unwrap();
    agent.send_message(message("/help")).await.unwrap();
}

#[tokio::test]
async fn core_rejects_empty_agent_result_and_does_not_emit_successful_finish() {
    let dir = tempfile::tempdir().unwrap();
    let server = server(vec![(finished(), vec![])], 4096).await;
    let mut config = resolved(&server.url, dir.path());
    config.max_turns = Some(1);
    let agent = AionrsAgentManager::new(
        "empty-session".into(),
        dir.path().to_string_lossy().into_owned(),
        config,
        None,
    )
    .await
    .unwrap();
    let mut events = agent.subscribe();
    let error = agent.send_message(message("synthetic empty result")).await.unwrap_err();
    assert!(
        error
            .stream_error()
            .detail
            .as_deref()
            .unwrap()
            .contains("no complete answer")
    );
    let mut failed = false;
    while let Ok(event) = events.try_recv() {
        match event {
            AgentStreamEvent::Error(_) => failed = true,
            AgentStreamEvent::Finish(_) => panic!("failed turn must not emit successful finish"),
            _ => {}
        }
    }
    assert!(failed);
    agent.send_message(message("/clear")).await.unwrap();
    agent.send_message(message("/help")).await.unwrap();
}

#[tokio::test]
async fn core_agent_streams_executes_tool_and_resumes_with_gateway_options() {
    for auth in [GatewayAuth::Bearer, GatewayAuth::None] {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("evidence.txt");
        std::fs::write(&file, "CONTROLLED_TOOL_RESULT_21").unwrap();
        let tool = json!({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-21","type":"function","extra_content":{"opaque":"synthetic-metadata"},"function":{"name":"Read","arguments":json!({"file_path":file}).to_string()}}]},"finish_reason":"tool_calls"}]});
        let head = b"data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Reading now\"}}]}\n\n".to_vec();
        let mut final_response =
            b"data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Read complete\"}}]}\n\n".to_vec();
        final_response.extend(finished());
        let mut server = server(
            vec![
                (head, format!("data:{tool}\n\ndata:[DONE]\n\n").into_bytes()),
                (final_response.clone(), vec![]),
                (final_response, vec![]),
            ],
            1,
        )
        .await;
        let endpoint = server
            .url
            .replace("/chat/completions", "/gateway/invoke/?tenant=synthetic");
        let mut config = resolved(&endpoint, dir.path());
        config.compat_overrides.gateway.as_mut().unwrap().auth = auth;
        if auth == GatewayAuth::None {
            config.api_key.clear();
        }
        let agent = Arc::new(
            AionrsAgentManager::new(
                "gateway-session".into(),
                dir.path().to_string_lossy().into_owned(),
                config.clone(),
                None,
            )
            .await
            .unwrap(),
        );
        let mut events = agent.subscribe();
        let task_agent = agent.clone();
        let task = tokio::spawn(async move { task_agent.send_message(message("Read the synthetic file")).await });
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if matches!(events.recv().await.unwrap(), AgentStreamEvent::Text(data) if data.content == "Reading now")
                {
                    break;
                }
            }
        })
        .await
        .unwrap();
        assert!(
            !task.is_finished(),
            "text must arrive while HTTP response is still blocked"
        );
        let headers = server.headers.recv().await.unwrap().to_ascii_lowercase();
        assert!(headers.starts_with("post /gateway/invoke/?tenant=synthetic http/1.1"));
        assert_eq!(
            headers.contains("authorization: bearer synthetic-key\r\n"),
            auth == GatewayAuth::Bearer
        );
        assert!(headers.contains("x-synthetic-key: synthetic-secret\r\n"));
        let first = server.requests.recv().await.unwrap();
        assert!(
            first["tools"]
                .as_array()
                .unwrap()
                .iter()
                .any(|tool| tool["function"]["name"] == "Read")
        );
        server.release.send(()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let next = server.requests.recv().await.unwrap();
        assert!(
            next["messages"]
                .as_array()
                .unwrap()
                .iter()
                .any(|m| m["role"] == "assistant"
                    && m["tool_calls"][0]["extra_content"] == json!({"opaque":"synthetic-metadata"}))
        );
        assert!(next["messages"].as_array().unwrap().iter().any(|m| m["role"] == "tool"
            && m["tool_call_id"] == "call-21"
            && m["content"].as_str().unwrap().contains("CONTROLLED_TOOL_RESULT_21")));
        let mut tool_completed = false;
        let mut final_text = false;
        while let Ok(event) = events.try_recv() {
            match event {
                AgentStreamEvent::ToolCall(data)
                    if data
                        .output
                        .as_deref()
                        .is_some_and(|v| v.contains("CONTROLLED_TOOL_RESULT_21")) =>
                {
                    tool_completed = true
                }
                AgentStreamEvent::Text(data) if data.content == "Read complete" => final_text = true,
                AgentStreamEvent::Error(data) => panic!("unexpected error: {data:?}"),
                _ => {}
            }
        }
        assert!(tool_completed && final_text);
        drop(agent);
        let sessions = aion_agent::session::SessionManager::new(config.session_directory.clone(), 100);
        let session = sessions.load("gateway-session").unwrap();
        let resumed = AionrsAgentManager::new(
            "gateway-session".into(),
            dir.path().to_string_lossy().into_owned(),
            config,
            Some(session),
        )
        .await
        .unwrap();
        resumed.send_message(message("Continue after resume")).await.unwrap();
        server.headers.recv().await.unwrap();
        let headers = server.headers.recv().await.unwrap().to_ascii_lowercase();
        assert!(headers.contains("x-synthetic-key: synthetic-secret\r\n"));
        let resumed_request = server.requests.recv().await.unwrap();
        assert!(
            resumed_request["messages"]
                .as_array()
                .unwrap()
                .iter()
                .any(|m| m["role"] == "tool" && m["tool_call_id"] == "call-21")
        );
    }
}

#[tokio::test]
async fn health_probe_uses_sdk_gateway_and_rejects_empty_response() {
    let dir = tempfile::tempdir().unwrap();
    let mut response = b"data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"}}]}\n\n".to_vec();
    response.extend(finished());
    let mut server = server(vec![(response, vec![]), (finished(), vec![])], 1).await;
    let config = resolved(&server.url, dir.path());
    let result = aionui_ai_agent::probe_resolved_provider("synthetic".into(), "openai".into(), config.clone())
        .await
        .unwrap();
    assert_eq!(result.status, aionui_api_types::HealthStatus::Healthy);
    let request = server.requests.recv().await.unwrap();
    assert_eq!(request["max_tokens"], 16);
    let result = aionui_ai_agent::probe_resolved_provider("synthetic".into(), "openai".into(), config)
        .await
        .unwrap();
    assert_eq!(result.status, aionui_api_types::HealthStatus::Unhealthy);
    assert!(result.message.as_deref().unwrap().contains("no complete answer"));
}

#[tokio::test]
async fn core_cancel_closes_pending_stream_and_does_not_emit_answer_or_run_tools() {
    let dir = tempfile::tempdir().unwrap();
    let mut server = server(vec![(vec![], finished())], 1).await;
    let agent = Arc::new(
        AionrsAgentManager::new(
            "cancel-session".into(),
            dir.path().to_string_lossy().into_owned(),
            resolved(&server.url, dir.path()),
            None,
        )
        .await
        .unwrap(),
    );
    let mut events = agent.subscribe();
    let running = agent.clone();
    let task = tokio::spawn(async move { running.send_message(message("wait for response")).await });
    tokio::time::timeout(Duration::from_secs(5), server.requests.recv())
        .await
        .unwrap()
        .unwrap();
    agent.cancel().await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    tokio::time::timeout(Duration::from_secs(2), server.disconnected.recv())
        .await
        .unwrap()
        .unwrap();
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, AgentStreamEvent::Text(_) | AgentStreamEvent::ToolCall(_)),
            "cancelled turn must not produce an answer or tools"
        );
    }
}

#[tokio::test]
async fn core_reports_partial_stream_failure_without_replaying_request() {
    let dir = tempfile::tempdir().unwrap();
    let response = b"data:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\ndata:{\"error\":{\"message\":\"synthetic-key\"}}\n\n".to_vec();
    let mut server = server(vec![(response, vec![]), (vec![], vec![])], 1).await;
    let agent = AionrsAgentManager::new(
        "error-session".into(),
        dir.path().to_string_lossy().into_owned(),
        resolved(&server.url, dir.path()),
        None,
    )
    .await
    .unwrap();
    let mut events = agent.subscribe();
    let error = agent.send_message(message("synthetic failure")).await.unwrap_err();
    assert!(error.stream_error().detail.as_deref().unwrap().contains("[REDACTED]"));
    assert!(
        !error
            .stream_error()
            .detail
            .as_deref()
            .unwrap()
            .contains("synthetic-key")
    );
    server.requests.recv().await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(1500), server.requests.recv())
            .await
            .is_err()
    );
    let mut partial = false;
    let mut failed = false;
    while let Ok(event) = events.try_recv() {
        match event {
            AgentStreamEvent::Text(data) if data.content == "partial" => partial = true,
            AgentStreamEvent::Error(_) => failed = true,
            AgentStreamEvent::Finish(_) => panic!("failed turn must not report successful finish"),
            _ => {}
        }
    }
    assert!(partial && failed);
}
