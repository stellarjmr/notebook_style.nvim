// The backend log, kept to a bounded size.
//
// Kernel stdout and stderr go into the log too, so it could grow without end.
// Once the log file reaches its limit it is renamed to `<name>.1` (replacing
// an older one) and a new file is started. A file that is already full is
// rotated by the first write (the backend logs a line as soon as it starts).
//
// Several backends (one per Neovim) share the file. Before each write a
// backend checks that the path still names the file it holds: if another
// backend has rotated it, or it was deleted, the backend opens the file now
// at the path. The size compared with the limit is the file's, so the limit
// holds for all backends together, give or take the lines they write while
// one of them is rotating. A backend rotates only while it holds the lock on
// `<name>.lock`, and checks the size again first, so a full log is rotated
// once even when several backends find it full at the same time. The lock is
// only tried, never waited for: a backend that does not get it (another one
// is rotating at that moment) writes its line to the file it holds, which
// then ends up in `.1`. A backend stopped while holding the lock therefore
// only delays rotation. Where the lock file cannot be opened or locking
// itself fails (a filesystem without flock), rotation goes without it.
//
// What stays on disk: about two limits, plus, until their next line, the
// files that idle backends still hold after others rotated past them. A
// line is lost only if two rotations happen between a backend's check and
// its write. Logging is best effort: if the check or a rotation fails, the
// backend keeps writing to the file it holds. The check compares device and
// inode numbers, which only Unix provides; elsewhere a backend only notices
// that the file is gone. On macOS, after many processes renamed and created
// the same name at once, `core.log` has been seen to resolve for a while to
// the file just renamed to `core.log.1` while not being listed; rotations
// then change nothing until that clears, and no line is lost.

use std::fs::{File, Metadata, OpenOptions, TryLockError};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub struct RotatingLog {
    path: PathBuf,
    file: File,
    limit: u64,
    /// `<name>.lock`; None if it could not be opened, and then rotation
    /// goes without it.
    lock: Option<File>,
}

impl RotatingLog {
    /// Open `path` for appending.
    pub fn open(path: PathBuf, limit: u64) -> io::Result<Self> {
        let file = open_append(&path)?;
        let lock = OpenOptions::new()
            .create(true)
            .write(true)
            .open(with_suffix(&path, ".lock"))
            .ok();
        Ok(Self {
            path,
            file,
            limit,
            lock,
        })
    }

    fn rotated_path(&self) -> PathBuf {
        with_suffix(&self.path, ".1")
    }

    /// Whether `len` more bytes would take the file at `path` past the limit.
    /// A line longer than the limit still goes into an empty file.
    fn full(&mut self, len: usize) -> bool {
        self.current_size()
            .is_ok_and(|size| size > 0 && size + len as u64 > self.limit)
    }

    /// Rotate the log if `len` more bytes would take it past the limit, under
    /// the lock (see the top of this file).
    fn rotate_if_full(&mut self, len: usize) {
        if !self.full(len) {
            return;
        }
        let Some(lock) = self.lock.take() else {
            let _ = self.rotate();
            return;
        };
        match lock.try_lock() {
            Ok(()) => {
                // Another backend may have rotated it since the check above.
                if self.full(len) {
                    let _ = self.rotate();
                }
                let _ = lock.unlock();
            }
            // Another backend is rotating it right now.
            Err(TryLockError::WouldBlock) => {}
            Err(TryLockError::Error(_)) => {
                let _ = self.rotate();
            }
        }
        self.lock = Some(lock);
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

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
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
        self.rotate_if_full(buf.len());
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
    fn a_backend_does_not_rotate_while_another_holds_the_lock() {
        let dir = Dir::new();
        let path = dir.0.join("core.log");
        std::fs::write(&path, "x".repeat(50)).unwrap();
        let mut log = RotatingLog::open(path, 40).unwrap();
        // Another backend in the middle of a rotation.
        let other = File::open(dir.0.join("core.log.lock")).unwrap();
        other.lock().unwrap();
        log.write_all(b"while locked\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "");
        assert_eq!(dir.read("core.log"), "x".repeat(50) + "while locked\n");
        other.unlock().unwrap();
        log.write_all(b"after\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "x".repeat(50) + "while locked\n");
        assert_eq!(dir.read("core.log"), "after\n");
    }

    #[test]
    fn a_line_longer_than_the_limit_goes_into_an_empty_log() {
        let dir = Dir::new();
        std::fs::write(dir.0.join("core.log.1"), "older\n").unwrap();
        let mut log = RotatingLog::open(dir.0.join("core.log"), 10).unwrap();
        log.write_all(b"longer than ten bytes\n").unwrap();
        // The empty log is not rotated over the previous one.
        assert_eq!(dir.read("core.log"), "longer than ten bytes\n");
        assert_eq!(dir.read("core.log.1"), "older\n");
        log.write_all(b"next\n").unwrap();
        assert_eq!(dir.read("core.log.1"), "longer than ten bytes\n");
        assert_eq!(dir.read("core.log"), "next\n");
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
