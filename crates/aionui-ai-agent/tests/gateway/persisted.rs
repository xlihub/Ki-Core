use super::*;
use aionui_ai_agent::ProviderHealthCheckService;
use aionui_ai_agent::types::SendMessageData;
use aionui_api_types::{CreateProviderRequest, ProviderHealthCheckRequest};
use serde_json::json;
use wiremock::{
    Mock, MockServer, ResponseTemplate,
    matchers::{method, path},
};

#[tokio::test]
async fn saved_manual_gateway_is_used_by_factory_resume_and_health() {
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/custom/invoke/"))
        .respond_with(ResponseTemplate::new(200).insert_header("content-type", "text/event-stream").set_body_string(
            "data:{\"model\":\"response-alias\",\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata:{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"))
        .expect(3).mount(&server).await;
    let (repo, registry, sessions) = setup().await;
    let service = aionui_system::ProviderService::new(repo.clone(), test_encryption_key());
    let req: CreateProviderRequest = serde_json::from_value(json!({
        "id":"saved-gateway", "platform":"custom", "name":"Saved gateway",
        "base_url":format!("{}/custom/invoke/", server.uri()), "is_full_url":true,
        "model_mode":"manual", "models":["request-model"],
        "gateway":{"auth":"none", "include_stream_options":false, "proxy":"direct", "headers":[{"name":"X-Key", "sensitive":true}, {"name":"X-Tenant", "value":"tenant"}]},
        "header_credentials":{"X-Key":{"action":"replace", "value":"synthetic-secret"}}
    })).unwrap();
    service.create(TEST_USER_ID, req).await.unwrap();
    let dir = tempfile::tempdir().unwrap();
    let conversation = format!("gateway-{}", uuid::Uuid::now_v7());
    let factory = make_factory(repo.clone(), registry, sessions);
    for _ in 0..2 {
        let agent = factory(make_aionrs_options(
            &conversation,
            dir.path().to_str().unwrap(),
            ProviderWithModel {
                provider_id: "saved-gateway".into(),
                model: "request-model".into(),
                use_model: None,
            },
            AionrsBuildExtra::default(),
        ))
        .await
        .unwrap();
        agent
            .send_message(SendMessageData {
                content: "Synthetic question".into(),
                msg_id: uuid::Uuid::now_v7().to_string(),
                turn_id: None,
                files: vec![],
                inject_skills: vec![],
            })
            .await
            .unwrap();
    }
    let health = ProviderHealthCheckService::new(repo.clone(), test_encryption_key(), dir.path().to_owned());
    let response = health
        .health_check(
            TEST_USER_ID,
            ProviderHealthCheckRequest {
                provider_id: "saved-gateway".into(),
                model: "request-model".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(response.status, aionui_api_types::HealthStatus::Healthy, "{response:?}");
    let requests = server.received_requests().await.unwrap();
    assert_eq!(requests.len(), 3);
    for request in requests {
        assert_eq!(request.headers.get("x-key").unwrap(), "synthetic-secret");
        assert_eq!(request.headers.get("x-tenant").unwrap(), "tenant");
        assert!(!request.headers.contains_key("authorization"));
        let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body["model"], "request-model");
        assert!(body.get("stream_options").is_none());
    }
    assert_eq!(
        repo.find_by_id(TEST_USER_ID, "saved-gateway")
            .await
            .unwrap()
            .unwrap()
            .models,
        "[\"request-model\"]"
    );
}

#[tokio::test]
async fn gateway_health_distinguishes_timeouts_from_http_failures() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(std::time::Duration::from_millis(300))
                .set_body_string("delayed"),
        )
        .mount(&server)
        .await;
    let (repo, _, _) = setup().await;
    let service = aionui_system::ProviderService::new(repo.clone(), test_encryption_key());
    service.create(TEST_USER_ID, serde_json::from_value(json!({"id":"timeout-gateway","platform":"custom","name":"Timeout","base_url":server.uri(),"api_key":"synthetic-key","models":["synthetic"],"gateway":{"request_timeout_ms":50,"read_timeout_ms":1000}})).unwrap()).await.unwrap();
    let dir = tempfile::tempdir().unwrap();
    let health = ProviderHealthCheckService::new(repo, test_encryption_key(), dir.path().to_owned());
    let result = health
        .health_check(
            TEST_USER_ID,
            ProviderHealthCheckRequest {
                provider_id: "timeout-gateway".into(),
                model: "synthetic".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(
        result.error_kind,
        Some(aionui_api_types::ProviderHealthCheckErrorKind::Timeout),
        "{result:?}"
    );
}

fn healthy_response() -> ResponseTemplate {
    ResponseTemplate::new(200).insert_header("content-type", "text/event-stream").set_body_string(
        "data:{\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata:{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata:[DONE]\n\n")
}

async fn saved_health_service(
    url: &str,
    gateway: serde_json::Value,
) -> (ProviderHealthCheckService, tempfile::TempDir) {
    let (repo, _, _) = setup().await;
    aionui_system::ProviderService::new(repo.clone(),test_encryption_key()).create(TEST_USER_ID,serde_json::from_value(json!({
        "id":"health-gateway","platform":"custom","name":"Health","base_url":url,"api_key":"synthetic-key","models":["synthetic"],"is_full_url":true,"model_mode":"manual","gateway":gateway
    })).unwrap()).await.unwrap();
    let dir = tempfile::tempdir().unwrap();
    (
        ProviderHealthCheckService::new(repo, test_encryption_key(), dir.path().to_owned()),
        dir,
    )
}
fn health_request() -> ProviderHealthCheckRequest {
    ProviderHealthCheckRequest {
        provider_id: "health-gateway".into(),
        model: "synthetic".into(),
    }
}

#[tokio::test]
async fn gateway_health_accepts_first_event_after_legacy_thirty_second_limit() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(healthy_response().set_delay(std::time::Duration::from_secs(31)))
        .expect(1)
        .mount(&server)
        .await;
    let (health, _dir) = saved_health_service(
        &server.uri(),
        json!({"proxy":"direct","read_timeout_ms":35000,"request_timeout_ms":40000}),
    )
    .await;
    let response = health.health_check(TEST_USER_ID, health_request()).await.unwrap();
    assert_eq!(response.status, aionui_api_types::HealthStatus::Healthy, "{response:?}");
    assert!(response.first_event_ms.unwrap() >= 30000);
    assert!(response.slow_first_event);
}

#[tokio::test]
async fn gateway_health_reports_explicit_cancellation() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(healthy_response().set_delay(std::time::Duration::from_secs(5)))
        .mount(&server)
        .await;
    let (health, _dir) = saved_health_service(&server.uri(), json!({"proxy":"direct"})).await;
    let cancellation = tokio_util::sync::CancellationToken::new();
    let token = cancellation.clone();
    let cancel = async {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        token.cancel();
    };
    let (response, ()) = tokio::join!(
        health.health_check_with_cancellation(TEST_USER_ID, health_request(), cancellation),
        cancel
    );
    assert_eq!(
        response.unwrap().error_kind,
        Some(aionui_api_types::ProviderHealthCheckErrorKind::Cancelled)
    );
}

#[tokio::test]
async fn gateway_proxy_policy_applies_only_to_its_client() {
    let origin = MockServer::start().await;
    let proxy = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(healthy_response())
        .expect(1)
        .mount(&origin)
        .await;
    Mock::given(method("POST"))
        .respond_with(healthy_response())
        .expect(1)
        .mount(&proxy)
        .await;
    for policy in ["default", "direct"] {
        let mut child = aionui_runtime::Builder::clean_cli(std::env::current_exe().unwrap());
        child
            .args(["--exact", "connection::gateway_proxy_client_child", "--nocapture"])
            .env("KI_TEST_GATEWAY_ENDPOINT", origin.uri())
            .env("KI_TEST_PROXY_POLICY", policy)
            .env("HTTP_PROXY", proxy.uri())
            .env("http_proxy", proxy.uri())
            .env("HTTPS_PROXY", proxy.uri())
            .env("https_proxy", proxy.uri())
            .env("ALL_PROXY", proxy.uri())
            .env("all_proxy", proxy.uri())
            .env("NO_PROXY", "")
            .env("no_proxy", "");
        let output = child.output().await.unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[tokio::test]
async fn gateway_proxy_client_child() {
    let Ok(url) = std::env::var("KI_TEST_GATEWAY_ENDPOINT") else {
        return;
    };
    let policy = std::env::var("KI_TEST_PROXY_POLICY").unwrap();
    let (health, _dir) = saved_health_service(&url, json!({"proxy":policy})).await;
    let response = health.health_check(TEST_USER_ID, health_request()).await.unwrap();
    assert_eq!(response.status, aionui_api_types::HealthStatus::Healthy, "{response:?}");
}

#[tokio::test]
async fn saved_auth_and_stream_options_updates_reach_the_sdk() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(healthy_response())
        .expect(2)
        .mount(&server)
        .await;
    let (repo, _, _) = setup().await;
    let service = aionui_system::ProviderService::new(repo.clone(), test_encryption_key());
    let gateway = json!({"auth":"bearer","include_stream_options":true,"headers":[{"name":"X-Secret","sensitive":true},{"name":"X-Tenant","value":"tenant"}]});
    service.create(TEST_USER_ID,serde_json::from_value(json!({"id":"health-gateway","platform":"custom","name":"Auth","base_url":server.uri(),"is_full_url":true,"model_mode":"manual","models":["synthetic"],"api_key":"synthetic-bearer","gateway":gateway,"header_credentials":{"x-secret":{"action":"replace","value":"synthetic-secret"}}})).unwrap()).await.unwrap();
    let dir = tempfile::tempdir().unwrap();
    let health = ProviderHealthCheckService::new(repo, test_encryption_key(), dir.path().to_owned());
    assert_eq!(
        health
            .health_check(TEST_USER_ID, health_request())
            .await
            .unwrap()
            .status,
        aionui_api_types::HealthStatus::Healthy
    );
    service.update(TEST_USER_ID,"health-gateway",serde_json::from_value(json!({"gateway":{"auth":"none","include_stream_options":false,"headers":gateway["headers"]},"api_key":""})).unwrap()).await.unwrap();
    assert_eq!(
        health
            .health_check(TEST_USER_ID, health_request())
            .await
            .unwrap()
            .status,
        aionui_api_types::HealthStatus::Healthy
    );
    let requests = server.received_requests().await.unwrap();
    assert_eq!(
        requests[0].headers.get("authorization").unwrap(),
        "Bearer synthetic-bearer"
    );
    assert!(!requests[1].headers.contains_key("authorization"));
    for request in &requests {
        assert_eq!(request.headers.get("x-secret").unwrap(), "synthetic-secret");
        assert_eq!(request.headers.get("x-tenant").unwrap(), "tenant");
    }
    let first: serde_json::Value = serde_json::from_slice(&requests[0].body).unwrap();
    let second: serde_json::Value = serde_json::from_slice(&requests[1].body).unwrap();
    assert_eq!(first["stream_options"], json!({"include_usage":true}));
    assert!(second.get("stream_options").is_none());
    service
        .update(
            TEST_USER_ID,
            "health-gateway",
            serde_json::from_value(json!({"header_credentials":{"X-Secret":{"action":"clear"}}})).unwrap(),
        )
        .await
        .unwrap();
    let error = health.health_check(TEST_USER_ID, health_request()).await.unwrap_err();
    assert!(error.to_string().contains("Missing gateway credential"));
    assert_eq!(server.received_requests().await.unwrap().len(), 2);
}

#[tokio::test]
async fn gateway_auth_and_unsupported_field_failures_are_identifiable_and_redacted() {
    for (status, expected) in [
        (401, aionui_api_types::ProviderHealthCheckErrorKind::Unauthorized),
        (400, aionui_api_types::ProviderHealthCheckErrorKind::InvalidRequest),
    ] {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(
                ResponseTemplate::new(status)
                    .set_body_json(json!({"error":{"message":"synthetic-key: unsupported stream_options"}})),
            )
            .mount(&server)
            .await;
        let (health, _dir) = saved_health_service(&server.uri(), json!({"include_stream_options":true})).await;
        let response = health.health_check(TEST_USER_ID, health_request()).await.unwrap();
        assert_eq!(response.error_kind, Some(expected), "{response:?}");
        assert_eq!(response.http_status, Some(status));
        assert!(!response.message.unwrap().contains("synthetic-key"));
    }
}

#[tokio::test]
async fn gateway_health_marks_truncated_output_as_interrupted() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string("data:{\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"),
        )
        .expect(1)
        .mount(&server)
        .await;
    let (health, _dir) = saved_health_service(&server.uri(), json!({})).await;
    let response = health.health_check(TEST_USER_ID, health_request()).await.unwrap();
    assert_eq!(
        response.error_kind,
        Some(aionui_api_types::ProviderHealthCheckErrorKind::Interrupted),
        "{response:?}"
    );
}

#[tokio::test]
async fn saved_connect_timeout_limits_a_stalled_tls_handshake() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("https://{}/invoke", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (_socket, _) = listener.accept().await.unwrap();
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    });
    let (health, _dir) = saved_health_service(
        &url,
        json!({"proxy":"direct","connect_timeout_ms":100,"read_timeout_ms":2000}),
    )
    .await;
    let response = health.health_check(TEST_USER_ID, health_request()).await.unwrap();
    server.abort();
    assert_eq!(
        response.error_kind,
        Some(aionui_api_types::ProviderHealthCheckErrorKind::Timeout),
        "{response:?}"
    );
    assert_eq!(response.timeout_stage.as_deref(), Some("connect"));
    assert!(response.elapsed_ms < 2000);
}

#[tokio::test]
async fn saved_read_timeout_closes_stalled_stream_without_reporting_success() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/invoke", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut header = Vec::new();
        while !header.ends_with(b"\r\n\r\n") {
            header.push(socket.read_u8().await.unwrap());
        }
        let length: usize = String::from_utf8_lossy(&header)
            .lines()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length: ")
                    .and_then(|n| n.parse().ok())
            })
            .unwrap();
        socket.read_exact(&mut vec![0; length]).await.unwrap();
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 9999\r\n\r\ndata:{\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n").await.unwrap();
        let disconnected = tokio::time::timeout(std::time::Duration::from_secs(3), socket.read_u8()).await;
        assert!(disconnected.unwrap().is_err());
    });
    let (health, _dir) = saved_health_service(
        &url,
        json!({"proxy":"direct","read_timeout_ms":100,"request_timeout_ms":2000}),
    )
    .await;
    let response = health.health_check(TEST_USER_ID, health_request()).await.unwrap();
    server.await.unwrap();
    // Ki-Model 0.1.1 converts body read errors to a string, losing is_timeout().
    assert_eq!(
        response.error_kind,
        Some(aionui_api_types::ProviderHealthCheckErrorKind::Interrupted),
        "{response:?}"
    );
    assert!(response.first_event_ms.is_some());
    assert!(response.elapsed_ms < 1500);
}
