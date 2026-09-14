//! Payload-free timing and usage observation at the SDK output boundary.
use aion_agent::output::OutputSink;
use std::{
    sync::{Arc, Mutex},
    time::Instant,
};

pub(crate) struct ProbeObservation {
    started: Instant,
    first_event_ms: Mutex<Option<u64>>,
}
impl ProbeObservation {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
            first_event_ms: Mutex::new(None),
        }
    }
    fn first(&self) {
        let mut first = self.first_event_ms.lock().unwrap_or_else(|e| e.into_inner());
        if first.is_none() {
            let elapsed = self.started.elapsed().as_millis().try_into().unwrap_or(u64::MAX);
            *first = Some(elapsed);
            tracing::info!(first_event_ms = elapsed, "Provider first output event");
        }
    }
    pub fn first_event_ms(&self) -> Option<u64> {
        *self.first_event_ms.lock().unwrap_or_else(|e| e.into_inner())
    }
}
impl OutputSink for ProbeObservation {
    fn emit_text_delta(&self, _text: &str, _msg_id: &str) {
        self.first();
    }
    fn emit_thinking(&self, _text: &str, _msg_id: &str) {
        self.first();
    }
    fn emit_tool_call(&self, _id: &str, _name: &str, _input: &str) {
        self.first();
    }
    fn emit_tool_result(&self, _id: &str, _name: &str, _error: bool, _content: &str) {}
    fn emit_stream_start(&self, _msg_id: &str) {}
    fn emit_stream_end(
        &self,
        _msg_id: &str,
        _turns: usize,
        input_tokens: u64,
        output_tokens: u64,
        cache_creation_tokens: u64,
        cache_read_tokens: u64,
    ) {
        tracing::info!(
            input_tokens,
            output_tokens,
            cache_creation_tokens,
            cache_read_tokens,
            "Provider probe usage"
        );
    }
    fn emit_error(&self, _message: &str) {}
    fn emit_info(&self, _message: &str) {}
}

/// Logs cancellation when the caller drops the probe future.
pub(crate) struct ProbeCompletion(pub bool);
impl Drop for ProbeCompletion {
    fn drop(&mut self) {
        if !self.0 {
            tracing::info!(end_state = "cancelled", "Provider probe dropped by caller");
        }
    }
}

pub(crate) type SharedObservation = Arc<ProbeObservation>;
