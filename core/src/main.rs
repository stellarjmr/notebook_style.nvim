// notebook-style-core — Jupyter notebook backend for Neovim
//
// Speaks msgpack-rpc over stdio to the Lua frontend.
// Speaks Jupyter wire protocol (ZMQ + HMAC-SHA256) to kernels.
// Owns .ipynb parsing/writing.

use anyhow::Result;
use std::path::PathBuf;
use std::sync::Mutex;
use tracing_subscriber::EnvFilter;

/// core.log is renamed to core.log.1 once it reaches this size (see logfile.rs).
const LOG_LIMIT: u64 = 10 * 1024 * 1024;

mod kernel;
mod kernelspec;
mod kitty;
mod logfile;
mod notebook;
mod protocol;
mod rpc;
mod session;

#[tokio::main]
async fn main() -> Result<()> {
    init_logging()?;
    tracing::info!(
        "notebook-style-core starting (v{})",
        env!("CARGO_PKG_VERSION")
    );

    let server = rpc::Server::new();
    server.run_stdio().await?;

    tracing::info!("notebook-style-core exiting cleanly");
    Ok(())
}

fn init_logging() -> Result<()> {
    let log_dir = dirs::cache_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("notebook_style");
    std::fs::create_dir_all(&log_dir)?;

    let log = logfile::RotatingLog::open(log_dir.join("core.log"), LOG_LIMIT)?;
    let env =
        EnvFilter::try_from_env("NOTEBOOK_STYLE_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(env)
        .with_writer(Mutex::new(log))
        .with_ansi(false)
        .with_target(true)
        .with_thread_ids(false)
        .init();

    Ok(())
}
