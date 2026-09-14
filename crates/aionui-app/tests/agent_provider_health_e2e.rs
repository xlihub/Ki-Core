//! Provider health-check route auth and validation tests.

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::json;
use tower::ServiceExt;

use common::{body_json, build_app, json_with_token, setup_and_login};

#[tokio::test]
async fn provider_health_check_unauthenticated_is_rejected() {
    let (app, _services) = build_app().await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/agents/provider-health-check")
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::to_vec(&json!({"provider_id": "p1", "model": "gpt-4o"})).unwrap(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();

    assert!(
        resp.status() == StatusCode::UNAUTHORIZED || resp.status() == StatusCode::FORBIDDEN,
        "expected auth rejection, got {}",
        resp.status()
    );
}

#[tokio::test]
async fn provider_health_check_requires_csrf_for_post() {
    let (mut app, services) = build_app().await;
    let (token, _csrf) = setup_and_login(&mut app, &services, "admin", "StrongP@ss1").await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/agents/provider-health-check")
        .header("content-type", "application/json")
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(
            serde_json::to_vec(&json!({"provider_id": "p1", "model": "gpt-4o"})).unwrap(),
        ))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn provider_health_check_validates_required_fields() {
    let (mut app, services) = build_app().await;
    let (token, csrf) = setup_and_login(&mut app, &services, "admin", "StrongP@ss1").await;

    let req = json_with_token(
        "POST",
        "/api/agents/provider-health-check",
        json!({"provider_id": "", "model": "gpt-4o"}),
        &token,
        &csrf,
    );
    let resp = app.oneshot(req).await.unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let json = body_json(resp).await;
    assert_eq!(json["code"], "BAD_REQUEST");
    assert!(
        json["error"]
            .as_str()
            .is_some_and(|message| message.contains("provider_id is required")),
        "expected provider_id validation error, got {json}"
    );
}

#[tokio::test]
async fn health_route_uses_gateway_saved_through_provider_api() {
    use wiremock::{
        Mock, MockServer, ResponseTemplate,
        matchers::{header, method, path},
    };
    let server = MockServer::start().await;
    Mock::given(method("POST")).and(path("/gateway/invoke/"))
        .and(header("x-synthetic-key","synthetic-secret"))
        .respond_with(ResponseTemplate::new(200).insert_header("content-type","text/event-stream").set_body_string(
            "data:{\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata:{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata:[DONE]\n\n"))
        .expect(1).mount(&server).await;
    let (mut app, services) = build_app().await;
    let (token, csrf) = setup_and_login(&mut app, &services, "admin", "StrongP@ss1").await;
    let response=app.clone().oneshot(json_with_token("POST","/api/providers",json!({
        "id":"api-gateway","platform":"custom","name":"Gateway","base_url":format!("{}/gateway/invoke/",server.uri()),"is_full_url":true,"model_mode":"manual","models":["synthetic-model"],
        "gateway":{"auth":"none","proxy":"direct","include_stream_options":false,"headers":[{"name":"X-Synthetic-Key","sensitive":true}]},
        "header_credentials":{"X-Synthetic-Key":{"action":"replace","value":"synthetic-secret"}}
    }),&token,&csrf)).await.unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    assert!(!body_json(response).await.to_string().contains("synthetic-secret"));
    let response = app
        .oneshot(json_with_token(
            "POST",
            "/api/agents/provider-health-check",
            json!({"provider_id":"api-gateway","model":"synthetic-model"}),
            &token,
            &csrf,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let response = body_json(response).await;
    assert_eq!(response["data"]["status"], "healthy", "{response}");
    let requests = server.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1);
    assert!(!requests[0].headers.contains_key("authorization"));
    let body: serde_json::Value = serde_json::from_slice(&requests[0].body).unwrap();
    assert_eq!(body["model"], "synthetic-model");
    assert!(body.get("stream_options").is_none());
}
