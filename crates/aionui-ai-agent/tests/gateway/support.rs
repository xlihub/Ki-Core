use std::time::Duration;

use aion_config::config::{CliArgs, Config};
use aion_types::{
    llm::LlmRequest,
    message::{ContentBlock, Message, Role},
};
use serde_json::Value;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::mpsc,
};

pub struct Server {
    pub url: String,
    pub requests: mpsc::Receiver<Value>,
    pub headers: mpsc::Receiver<String>,
    pub release: mpsc::Sender<()>,
    pub disconnected: mpsc::Receiver<()>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub async fn server(responses: Vec<(Vec<u8>, Vec<u8>)>, fragment: usize) -> Server {
    http_server(responses, fragment, 200, "text/event-stream").await
}

pub async fn http_server(
    responses: Vec<(Vec<u8>, Vec<u8>)>,
    fragment: usize,
    status: u16,
    content_type: &'static str,
) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let (headers_tx, headers) = mpsc::channel(16);
    let (request_tx, requests) = mpsc::channel(16);
    let (closed_tx, disconnected) = mpsc::channel(16);
    let (release, mut gates) = mpsc::channel(16);
    let task = tokio::spawn(async move {
        for (head, tail) in responses {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let end = loop {
                bytes.push(socket.read_u8().await.unwrap());
                if bytes.ends_with(b"\r\n\r\n") {
                    break bytes.len();
                }
            };
            let headers = String::from_utf8_lossy(&bytes);
            headers_tx.send(headers.to_string()).await.unwrap();
            let length: usize = headers
                .lines()
                .find_map(|l| l.to_lowercase().strip_prefix("content-length: ").map(str::to_owned))
                .unwrap()
                .parse()
                .unwrap();
            bytes.resize(end + length, 0);
            socket.read_exact(&mut bytes[end..]).await.unwrap();
            request_tx
                .send(serde_json::from_slice(&bytes[end..]).unwrap())
                .await
                .unwrap();
            let header = format!(
                "HTTP/1.1 {status} Synthetic\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                head.len() + tail.len()
            );
            socket.write_all(header.as_bytes()).await.unwrap();
            for chunk in head.chunks(fragment) {
                if socket.write_all(chunk).await.is_err() {
                    break;
                }
                tokio::task::yield_now().await;
            }
            if !tail.is_empty() {
                tokio::select! {
                    _ = gates.recv() => { let _ = socket.write_all(&tail).await; },
                    result = socket.read_u8() => { assert!(result.is_err(), "client must close the stream"); let _ = closed_tx.send(()).await; },
                }
            }
        }
    });
    Server {
        url,
        requests,
        headers,
        release,
        disconnected,
        task,
    }
}

pub fn config(url: &str) -> Config {
    let mut config = Config::resolve(&CliArgs {
        provider: Some("openai".into()),
        api_key: Some("synthetic-key".into()),
        base_url: Some(url.into()),
        model: Some("synthetic-model".into()),
        max_tokens: None,
        max_turns: Some(4),
        max_tool_call_malformed_turns: Some(1),
        max_tool_call_failure_turns: Some(1),
        system_prompt: Some("Synthetic system".into()),
        thinking: None,
        thinking_budget: None,
        profile: None,
        auto_approve: false,
        project_dir: None,
    })
    .unwrap();
    config.compat.transport.api_path = Some(String::new());
    config.session.enabled = false;
    config.mcp.servers.clear();
    config
}

pub fn request() -> LlmRequest {
    LlmRequest {
        model: "synthetic-model".into(),
        system: "Synthetic system".into(),
        messages: vec![Message::new(
            Role::User,
            vec![ContentBlock::Text { text: "Hello".into() }],
        )],
        tools: vec![],
        max_tokens: Some(32),
        thinking: None,
        reasoning_effort: None,
    }
}

pub async fn event(rx: &mut mpsc::Receiver<aion_types::llm::LlmEvent>) -> aion_types::llm::LlmEvent {
    tokio::time::timeout(Duration::from_secs(5), rx.recv())
        .await
        .unwrap()
        .expect("event channel closed")
}

pub fn finished() -> Vec<u8> {
    b"data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata:[DONE]\n\n".to_vec()
}
