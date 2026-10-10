// The backend log, kept to a bounded size.
//
// Kernel stdout and stderr go into the log too, so it could grow without end.
// Once the log file reaches its limit it is renamed to `<name>.1` (replacing
// an older one) and a new file is started, so at most about two limits' worth
// of log stays on disk. A file that is already full is rotated by the first
// write (the backend logs a line as soon as it starts).
//
// Several backends (one per Neovim) share the file. Before each write a
// backend checks that the path still names the file it holds: if another
// backend has rotated it, or it was deleted, the backend opens the file now
// at the path. So no backend keeps writing to a file that another rotation
// removes, and a full log is rotated once, not once per backend. The size
// compared with the limit is the file's, so the limit holds for all backends
// together, give or take one line each. Two backends that both check and
// then rename within the same few microseconds can still rotate twice. The
// check compares device and inode numbers, which only Unix provides;
// elsewhere a backend only notices that the file is gone.

use std::fs::{File, Metadata, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub struct RotatingLog {
    path: PathBuf,
    file: File,
    limit: u64,
}

impl RotatingLog {
    /// Open `path` for appending.
    pub fn open(path: PathBuf, limit: u64) -> io::Result<Self> {
        let file = open_append(&path)?;
        Ok(Self { path, file, limit })
    }

    fn rotated_path(&self) -> PathBuf {
        let mut name = self.path.clone().into_os_string();
        name.push(".1");
        PathBuf::from(name)
    }

    /// The size of the file at `path`, after switching to that file if it is
    /// not the one held (another backend rotated it, or it was deleted).
    fn current_size(&mut self) -> io::Result<u64> {
        let held = self.file.metadata()?;
        match std::fs::metadata(&self.path) {
            Ok(at_path) if same_file(&held, &at_path) => Ok(held.len()),
            _ => {
                self.file = open_append(&self.path)?;
                Ok(self.file.metadata()?.len())
            }
        }
    }

    fn rotate(&mut self) -> io::Result<()> {
        match std::fs::rename(&self.path, self.rotated_path()) {
            // Another backend rotated it in the meantime.
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        self.file = open_append(&self.path)?;
        Ok(())
    }
}

fn open_append(path: &Path) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(path)
}

#[cfg(unix)]
fn same_file(a: &Metadata, b: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    a.dev() == b.dev() && a.ino() == b.ino()
}

#[cfg(not(unix))]
fn same_file(_: &Metadata, _: &Metadata) -> bool {
    true
}

impl Write for RotatingLog {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        // If checking or rotating fails, keep logging to the file held.
        if let Ok(size) = self.current_size() {
            if size > 0 && size + buf.len() as u64 > self.limit {
                let _ = self.rotate();
            }
        }
        self.file.write(buf)
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

    // Two backends sharing the log are two RotatingLogs on one path.

    #[test]
    fn a_backend_writes_to_the_file_another_backend_started() {
        let dir = Dir::new();
        let path = dir.0.join("core.log");
        let mut ours = RotatingLog::open(path.clone(), 30).unwrap();
        let mut theirs = RotatingLog::open(path, 30).unwrap();
        ours.write_all(b"ours 1 0123456\n").unwrap();
        theirs.write_all(b"theirs 1 01234\n").unwrap();
        // The file is full with both lines: ours rotates it, and theirs
        // follows to the new file, twice.
        ours.write_all(b"ours 2 0123456\n").unwrap();
        theirs.write_all(b"theirs 2 01234\n").unwrap();
        ours.write_all(b"ours 3 0123456\n").unwrap();
        theirs.write_all(b"theirs 3 01234\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "ours 2 0123456\ntheirs 2 01234\n");
        assert_eq!(dir.read("core.log"), "ours 3 0123456\ntheirs 3 01234\n");
    }

    #[test]
    fn backends_that_open_a_full_log_rotate_it_once() {
        let dir = Dir::new();
        let path = dir.0.join("core.log");
        std::fs::write(&path, "x".repeat(50)).unwrap();
        let mut first = RotatingLog::open(path.clone(), 40).unwrap();
        let mut second = RotatingLog::open(path, 40).unwrap();
        first.write_all(b"first starting\n").unwrap();
        second.write_all(b"second starting\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "x".repeat(50));
        assert_eq!(dir.read("core.log"), "first starting\nsecond starting\n");
    }

    #[test]
    fn a_deleted_log_is_created_again() {
        let dir = Dir::new();
        let path = dir.0.join("core.log");
        let mut log = RotatingLog::open(path.clone(), 100).unwrap();
        log.write_all(b"before\n").unwrap();
        std::fs::remove_file(&path).unwrap();
        log.write_all(b"after\n").unwrap();
        assert_eq!(dir.read("core.log"), "after\n");
    }
}
