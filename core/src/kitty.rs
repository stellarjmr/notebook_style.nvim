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
            inner: Arc::new(Mutex::new(KittyTtyInner { path: p })),
        })
    }

    fn write(&self, bytes: &[u8]) -> Result<()> {
        let inner = self.inner.lock();
        let mut f = OpenOptions::new()
            .write(true)
            .open(&inner.path)
            .map_err(|e| anyhow!("tty open: {e}"))?;
        f.write_all(bytes).map_err(|e| anyhow!("tty write: {e}"))?;
        f.flush().ok();
        Ok(())
    }

    /// Transmit a PNG to the terminal in virtual-placement mode.
    /// Returns the image_id the caller should use when emitting placeholders.
    pub fn transmit_png(&self, png: &[u8]) -> Result<u32> {
        let id = alloc_id();
        self.transmit_png_with_id(id, png)?;
        Ok(id)
    }

    pub fn transmit_png_with_id(&self, id: u32, png: &[u8]) -> Result<()> {
        let b64 = base64::engine::general_purpose::STANDARD.encode(png);
        let chunk = 4096;
        let mut pos = 0;
        let total = b64.len();
        let mut first = true;
        let mut buf = String::with_capacity(8192);
        while pos < total {
            let end = (pos + chunk).min(total);
            let part = &b64[pos..end];
            let more = if end < total { 1 } else { 0 };
            buf.clear();
            if first {
                // a=t: transmit only (no immediate placement)
                // f=100: PNG
                // U=1: virtual placement (Unicode placeholder mode)
                // q=2: suppress responses
                buf.push_str(&format!(
                    "\x1b_Ga=t,f=100,i={},U=1,q=2,m={};{}\x1b\\",
                    id, more, part
                ));
                first = false;
            } else {
                buf.push_str(&format!("\x1b_Gm={},q=2;{}\x1b\\", more, part));
            }
            self.write(buf.as_bytes())?;
            pos = end;
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
}
