use std::sync::Arc;

use aionui_conversation::ConversationService;
use aionui_cron::mcp_snapshot::{CronMcpSnapshotError, ICronMcpSnapshotResolver, ResolvedCronMcpSnapshot};

pub(crate) struct CronMcpSnapshotResolver {
    conversation_service: Arc<ConversationService>,
}

impl CronMcpSnapshotResolver {
    pub(crate) fn new(conversation_service: Arc<ConversationService>) -> Self {
        Self { conversation_service }
    }
}

#[async_trait::async_trait]
impl ICronMcpSnapshotResolver for CronMcpSnapshotResolver {
    async fn resolve(
        &self,
        user_id: &str,
        selected_ids: &[String],
    ) -> Result<ResolvedCronMcpSnapshot, CronMcpSnapshotError> {
        let selection = self
            .conversation_service
            .resolve_mcp_selection_for_ids(user_id, selected_ids)
            .await
            .map_err(|error| CronMcpSnapshotError::new(error.to_string()))?;

        if !selection.mcp_statuses.is_empty() {
            let failures = selection
                .mcp_statuses
                .iter()
                .map(|status| match status.reason.as_deref() {
                    Some(reason) => format!("{}: {reason}", status.name),
                    None => status.name.clone(),
                })
                .collect::<Vec<_>>()
                .join("; ");
            return Err(CronMcpSnapshotError::new(format!(
                "selected builtin MCP server resolution failed: {failures}"
            )));
        }

        Ok(ResolvedCronMcpSnapshot {
            mcp_server_ids: selection.mcp_server_ids,
            session_mcp_servers: selection.session_mcp_servers,
        })
    }
}
