//! Core configuration and client assembly for the Ki-Model SDK.
mod gateway;

pub use gateway::{GatewayAuth, GatewayConfig, GatewayCreationError, create_provider};
