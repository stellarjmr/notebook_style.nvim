// Native Kitty graphics protocol implementation.
//
// Strategy: Unicode placeholder mode (a=t, U=1).
//   1. Transmit image bytes once with `a=t f=100 i=ID U=1 q=2` (chunked)
//   2. Frontend (Lua) renders Unicode placeholder chars (U+10EEEE) in the
//      buffer with foreground color encoding the image ID.
//   3. Kitty/Ghostty intercepts placeholders at render time and draws the
//      image. Survives Neovim redraws because placeholders ARE buffer text.
//
// We open /dev/tty for direct write — bypasses Neovim's TUI multiplexing.

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use parking_lot::Mutex;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

static NEXT_IMAGE_ID: AtomicU32 = AtomicU32::new(1);

pub fn alloc_id() -> u32 {
    NEXT_IMAGE_ID.fetch_add(1, Ordering::Relaxed)
}

#[derive(Clone)]
pub struct KittyTty {
    inner: Arc<Mutex<KittyTtyInner>>,
}

struct KittyTtyInner {
    path: PathBuf,
    in_tmux: bool,
}

fn tmux_passthrough_enabled() -> bool {
    std::env::var_os("TMUX").is_some()
        && std::env::var_os("NOTEBOOK_STYLE_DISABLE_TMUX_PASSTHROUGH").is_none()
}

fn tmux_wrap(bytes: &[u8]) -> Vec<u8> {
    let mut wrapped = Vec::with_capacity(bytes.len() * 2 + 16);
    wrapped.extend_from_slice(b"\x1bPtmux;");
    for &b in bytes {
        wrapped.push(b);
        if b == 0x1b {
            wrapped.push(0x1b);
        }
    }
    wrapped.extend_from_slice(b"\x1b\\");
    wrapped
}

fn build_transmit_chunks(id: u32, png: &[u8]) -> Vec<String> {
    let b64 = base64::engine::general_purpose::STANDARD.encode(png);
    let chunk = 4096;
    let mut pos = 0;
    let total = b64.len();
    let mut first = true;
    let mut chunks = Vec::new();

    while pos < total {
        let end = (pos + chunk).min(total);
        let part = &b64[pos..end];
        let more = if end < total { 1 } else { 0 };
        if first {
            // a=t: transmit only; Neovim's Unicode placeholders decide where
            // the terminal draws the image.
            // f=100: PNG
            // U=1: Unicode placeholder mode
            // q=2: suppress responses
            chunks.push(format!(
                "\x1b_Ga=t,f=100,i={},U=1,q=2,m={};{}\x1b\\",
                id, more, part
            ));
            first = false;
        } else {
            chunks.push(format!("\x1b_Gm={},q=2;{}\x1b\\", more, part));
        }
        pos = end;
    }

    chunks
}

impl KittyTty {
    pub fn open(path: Option<PathBuf>) -> Result<Self> {
        let p = path.unwrap_or_else(|| PathBuf::from("/dev/tty"));
        // Sanity: open once to verify writable
        OpenOptions::new()
            .write(true)
            .open(&p)
            .with_context(|| format!("cannot open tty {}", p.display()))?;
        Ok(Self {
            inner: Arc::new(Mutex::new(KittyTtyInner {
                path: p,
                in_tmux: tmux_passthrough_enabled(),
            })),
        })
    }

    fn write(&self, bytes: &[u8]) -> Result<()> {
        let inner = self.inner.lock();
        let mut f = OpenOptions::new()
            .write(true)
            .open(&inner.path)
            .map_err(|e| anyhow!("tty open: {e}"))?;
        if inner.in_tmux {
            let wrapped = tmux_wrap(bytes);
            f.write_all(&wrapped)
                .map_err(|e| anyhow!("tty write: {e}"))?;
        } else {
            f.write_all(bytes).map_err(|e| anyhow!("tty write: {e}"))?;
        }
        f.flush().ok();
        Ok(())
    }

    /// Transmit a PNG to the terminal for Unicode-placeholder rendering.
    /// Returns the image_id the caller should use when emitting placeholders.
    pub fn transmit_png(&self, png: &[u8], cols: u32, rows: u32) -> Result<u32> {
        let id = alloc_id();
        self.transmit_png_with_id(id, png, cols, rows)?;
        Ok(id)
    }

    pub fn transmit_png_with_id(&self, id: u32, png: &[u8], _cols: u32, _rows: u32) -> Result<()> {
        for chunk in build_transmit_chunks(id, png) {
            self.write(chunk.as_bytes())?;
        }
        Ok(())
    }

    /// Delete a single image from the terminal's memory and any active placements.
    pub fn delete_image(&self, id: u32) -> Result<()> {
        let s = format!("\x1b_Ga=d,d=I,i={},q=2\x1b\\", id);
        self.write(s.as_bytes())
    }

    /// Delete all images.
    pub fn delete_all(&self) -> Result<()> {
        self.write(b"\x1b_Ga=d,d=A,q=2\x1b\\")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alloc_ids_unique() {
        let a = alloc_id();
        let b = alloc_id();
        assert_ne!(a, b);
    }

    #[test]
    fn open_nonexistent_tty_fails() {
        let r = KittyTty::open(Some(PathBuf::from("/nonexistent/tty")));
        assert!(r.is_err());
    }

    #[test]
    fn tmux_wrap_doubles_internal_escapes() {
        let wrapped = tmux_wrap(b"\x1b_Gq=2;\x1b\\");
        assert_eq!(wrapped, b"\x1bPtmux;\x1b\x1b_Gq=2;\x1b\x1b\\\x1b\\");
    }

    #[test]
    fn transmit_escape_does_not_create_cursor_placement() {
        let chunks = build_transmit_chunks(42, b"png-bytes");
        assert_eq!(chunks.len(), 1);
        assert!(chunks[0].starts_with("\x1b_Ga=t,"));
        assert!(chunks[0].contains("U=1"));
        assert!(!chunks[0].contains("a=T"));
        assert!(!chunks[0].contains(",c="));
        assert!(!chunks[0].contains(",r="));
    }
}
