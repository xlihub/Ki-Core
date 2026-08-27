use aionui_api_types::SessionMcpServer;

/// Runtime MCP values that Cron persists into a newly created conversation.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResolvedCronMcpSnapshot {
    pub mcp_server_ids: Vec<String>,
    pub session_mcp_servers: Vec<SessionMcpServer>,
}

#[derive(Debug, thiserror::Error)]
#[error("{message}")]
pub struct CronMcpSnapshotError {
    message: String,
}

impl CronMcpSnapshotError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

/// Resolves a persisted Cron MCP selection without coupling Cron to the
/// conversation domain's richer selection model.
#[async_trait::async_trait]
pub trait ICronMcpSnapshotResolver: Send + Sync {
    async fn resolve(
        &self,
        user_id: &str,
        selected_ids: &[String],
    ) -> Result<ResolvedCronMcpSnapshot, CronMcpSnapshotError>;
}
