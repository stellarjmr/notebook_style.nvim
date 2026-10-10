// The backend log, kept to a bounded size.
//
// Kernel stdout and stderr go into the log too, so it could grow without end.
// Once the log file reaches its limit it is renamed to `<name>.1` (replacing
// an older one) and a new file is started, so at most about two limits' worth
// of log stays on disk. The count starts from the file's size when it is
// opened, so a file that is already full is rotated by the first write (the
// backend logs a line as soon as it starts).
//
// Several backends (one per Neovim) share the file. Each counts only its own
// writes, from the size the file had when it opened it, so with N backends
// running the bound is roughly N times the limit. Renaming is atomic and no
// file is ever truncated: a backend still writing to a file another one has
// renamed loses nothing, and rotates again when its own count reaches the
// limit.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;

pub struct RotatingLog {
    path: PathBuf,
    file: File,
    /// Bytes in the file when it was opened, plus this process's writes.
    size: u64,
    limit: u64,
}

impl RotatingLog {
    /// Open `path` for appending.
    pub fn open(path: PathBuf, limit: u64) -> io::Result<Self> {
        let (file, size) = open_append(&path)?;
        Ok(Self {
            path,
            file,
            size,
            limit,
        })
    }

    fn rotated_path(&self) -> PathBuf {
        let mut name = self.path.clone().into_os_string();
        name.push(".1");
        PathBuf::from(name)
    }

    fn rotate(&mut self) -> io::Result<()> {
        match std::fs::rename(&self.path, self.rotated_path()) {
            // Another backend may have rotated the file already.
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        let (file, size) = open_append(&self.path)?;
        self.file = file;
        self.size = size;
        Ok(())
    }
}

fn open_append(path: &PathBuf) -> io::Result<(File, u64)> {
    let file = OpenOptions::new().create(true).append(true).open(path)?;
    let size = file.metadata()?.len();
    Ok((file, size))
}

impl Write for RotatingLog {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.size > 0 && self.size + buf.len() as u64 > self.limit {
            // If rotating fails, keep logging to the current file.
            let _ = self.rotate();
        }
        let written = self.file.write(buf)?;
        self.size += written as u64;
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Dir(PathBuf);

    impl Dir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("nbs-logfile-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&dir).unwrap();
            Self(dir)
        }
        fn read(&self, name: &str) -> String {
            std::fs::read_to_string(self.0.join(name)).unwrap_or_default()
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_full_log_is_renamed_and_a_new_one_started() {
        let dir = Dir::new();
        let mut log = RotatingLog::open(dir.0.join("core.log"), 20).unwrap();
        log.write_all(b"first line 0123456\n").unwrap();
        log.write_all(b"second line\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "first line 0123456\n");
        assert_eq!(dir.read("core.log"), "second line\n");

        // The next rotation replaces the older file.
        log.write_all(b"third line 01234\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "second line\n");
        assert_eq!(dir.read("core.log"), "third line 01234\n");
    }

    #[test]
    fn a_log_that_is_already_full_is_rotated_by_the_first_write() {
        let dir = Dir::new();
        std::fs::write(dir.0.join("core.log"), "x".repeat(30)).unwrap();
        let mut log = RotatingLog::open(dir.0.join("core.log"), 20).unwrap();
        log.write_all(b"new\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "x".repeat(30));
        assert_eq!(dir.read("core.log"), "new\n");
    }

    #[test]
    fn a_log_rotated_by_another_backend_is_reopened() {
        let dir = Dir::new();
        let path = dir.0.join("core.log");
        let mut ours = RotatingLog::open(path.clone(), 20).unwrap();
        let mut theirs = RotatingLog::open(path, 20).unwrap();
        ours.write_all(b"ours 0123456789\n").unwrap();
        theirs.write_all(b"theirs 012345\n").unwrap();
        // Ours reaches its limit first and rotates; theirs keeps writing to
        // the renamed file until its own count reaches the limit.
        ours.write_all(b"ours again\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "ours 0123456789\ntheirs 012345\n");
        assert_eq!(dir.read("core.log"), "ours again\n");
        theirs.write_all(b"theirs again\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "ours again\n");
        assert_eq!(dir.read("core.log"), "theirs again\n");
    }
}
