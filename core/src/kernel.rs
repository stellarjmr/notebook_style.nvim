// Spawn a Jupyter kernel and own its 5 ZMQ sockets (shell, iopub, stdin, control, hb).
//
// Connection-file based handshake: write JSON with random ports + HMAC key, kernel
// reads it via {connection_file} substitution in argv, then we connect.

use anyhow::{anyhow, Context, Result};
use bytes::Bytes;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, Mutex};
use uuid::Uuid;
use zeromq::{DealerSocket, Socket, SocketRecv, SocketSend, SubSocket, ZmqMessage};

use crate::kernelspec::KernelSpec;
use crate::protocol::{self, Message};

/// How long a kernel may take to open its ports before its start is abandoned.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(60);
/// Trailing stderr lines kept to explain a kernel that fails to start.
const STDERR_TAIL_LINES: usize = 20;
/// Longer kernel output lines are truncated when logged.
const MAX_LINE_BYTES: usize = 4096;
/// How often to check whether a starting kernel has opened its ports.
const PORT_POLL_INTERVAL: Duration = Duration::from_millis(20);
/// Connection attempts after the kernel's ports looked open.
const CONNECT_ATTEMPTS: usize = 5;
/// How often to check whether a running kernel's process is still alive.
const EXIT_POLL_INTERVAL: Duration = Duration::from_millis(500);

/// The last lines of a kernel's stderr, plus the line it is still writing.
#[derive(Default)]
struct Tail {
    lines: VecDeque<String>,
    partial: String,
}

type OutputTail = Arc<parking_lot::Mutex<Tail>>;

/// Lossy UTF-8 text of a kernel output line, at most MAX_LINE_BYTES long.
fn line_text(line: &[u8]) -> String {
    let mut text = String::from_utf8_lossy(line)
        .trim_end_matches('\r')
        .to_string();
    // A cut multibyte character becomes U+FFFD, which can make the text
    // longer than the bytes it came from.
    while text.len() > MAX_LINE_BYTES {
        text.pop();
    }
    text
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionInfo {
    pub ip: String,
    pub transport: String,
    pub shell_port: u16,
    pub iopub_port: u16,
    pub stdin_port: u16,
    pub control_port: u16,
    pub hb_port: u16,
    pub key: String,
    pub signature_scheme: String,
    pub kernel_name: String,
}

impl ConnectionInfo {
    pub fn new_localhost(kernel_name: &str) -> Result<Self> {
        let ports = pick_ports(5)?;
        Ok(Self::with_ports(
            kernel_name,
            [ports[0], ports[1], ports[2], ports[3], ports[4]],
        ))
    }

    /// All ports 0: for a kernel that binds ports itself and writes them back
    /// into its connection file (see `binds_own_ports`).
    fn unbound(kernel_name: &str) -> Self {
        Self::with_ports(kernel_name, [0; 5])
    }

    /// `ports` in the order shell, iopub, stdin, control, hb.
    fn with_ports(kernel_name: &str, ports: [u16; 5]) -> Self {
        Self {
            ip: "127.0.0.1".to_string(),
            transport: "tcp".to_string(),
            shell_port: ports[0],
            iopub_port: ports[1],
            stdin_port: ports[2],
            control_port: ports[3],
            hb_port: ports[4],
            key: Uuid::new_v4().to_string(),
            signature_scheme: "hmac-sha256".to_string(),
            kernel_name: kernel_name.to_string(),
        }
    }

    pub fn endpoint(&self, port: u16) -> String {
        format!("{}://{}:{}", self.transport, self.ip, port)
    }
}

/// Whether the kernelspec runs ipykernel directly: an interpreter, options
/// written as one word each (like `-Xfrozen_modules=off`), then
/// `-m ipykernel_launcher` (what `ipykernel install` writes, and the
/// auto_venv kernels) or `-m ipykernel`. ipykernel binds the ports it finds
/// as 0 in its connection file and writes the ports it bound back into that
/// file. Other kernels are given ports picked here, which something else
/// can take in the moment between picking and binding. So are kernelspecs
/// that hand the file to a wrapper (`sh -c ...`, `conda run ...`, tools that
/// forward the ports to another machine): the wrapper may need the ports in
/// the file, and the kernel it starts may not write back to that file.
/// `:checkhealth` uses the same rule (`ipykernel_options` in
/// lua/notebook_style/health.lua). The heartbeat port is the exception:
/// ipykernel picks a free port and binds it a moment later, as the backend
/// used to. The backend does not use the heartbeat.
fn binds_own_ports(spec: &KernelSpec) -> bool {
    let mut args = spec
        .argv
        .iter()
        .skip(1)
        .skip_while(|arg| arg.starts_with('-') && arg.as_str() != "-m");
    args.next().is_some_and(|arg| arg == "-m")
        && args
            .next()
            .is_some_and(|module| module == "ipykernel_launcher" || module == "ipykernel")
}

fn pick_ports(n: usize) -> Result<Vec<u16>> {
    use std::net::TcpListener;
    let mut ports = Vec::with_capacity(n);
    let mut listeners = Vec::with_capacity(n);
    for _ in 0..n {
        let l = TcpListener::bind("127.0.0.1:0")?;
        let p = l.local_addr()?.port();
        ports.push(p);
        listeners.push(l);
    }
    drop(listeners); // release before kernel binds
    Ok(ports)
}

/// Output produced by a running cell or kernel idle/busy transitions, etc.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum KernelEvent {
    /// The kernel process exited by itself (not through `Kernel::kill`).
    Exited {
        status: String,
        /// "; stderr:\n<last lines>" or "" (see `format_tail`).
        stderr: String,
    },
    Stream {
        msg_id: String,
        parent_msg_id: Option<String>,
        name: String, // "stdout" | "stderr"
        text: String,
    },
    DisplayData {
        msg_id: String,
        parent_msg_id: Option<String>,
        data: Value, // mime bundle
        metadata: Value,
        transient: Value,
    },
    ExecuteResult {
        msg_id: String,
        parent_msg_id: Option<String>,
        execution_count: u64,
        data: Value,
        metadata: Value,
    },
    Error {
        msg_id: String,
        parent_msg_id: Option<String>,
        ename: String,
        evalue: String,
        traceback: Vec<String>,
    },
    Status {
        execution_state: String, // "busy" | "idle" | "starting"
        parent_msg_id: Option<String>,
    },
    ExecuteInput {
        parent_msg_id: Option<String>,
        execution_count: u64,
        code: String,
    },
    ExecuteReply {
        parent_msg_id: Option<String>,
        status: String, // "ok" | "error" | "abort"
        execution_count: u64,
    },
    UpdateDisplayData {
        msg_id: String,
        parent_msg_id: Option<String>,
        data: Value,
        metadata: Value,
        transient: Value,
    },
    ClearOutput {
        parent_msg_id: Option<String>,
        wait: bool,
    },
    KernelInfo {
        parent_msg_id: Option<String>,
        info: Value,
    },
}

pub struct Kernel {
    spec: KernelSpec,
    conn: ConnectionInfo,
    /// Kept for the kernel's lifetime; removed when the kernel is dropped.
    _conn_file: ConnectionFile,
    session: String,
    child: Arc<Mutex<Child>>,
    /// Set by `kill`, so the exit it causes is not reported as a crash.
    killed: Arc<AtomicBool>,
    /// Outgoing-frame channel for shell socket (the socket-owning task drains this)
    shell_tx: mpsc::UnboundedSender<ZmqMessage>,
    /// Outgoing-frame channel for control socket
    control_tx: mpsc::UnboundedSender<ZmqMessage>,
    iopub_handle: tokio::task::JoinHandle<()>,
    /// Take this once with `take_events()` and drive it from a single consumer task.
    events: Mutex<Option<mpsc::UnboundedReceiver<KernelEvent>>>,
    /// Outstanding shell requests awaiting their reply, keyed by msg_id.
    /// `complete` and `inspect` register a oneshot here BEFORE sending so the
    /// socket owner can deliver the matching reply directly. execute_request
    /// uses iopub events for streaming output and doesn't wait on this map.
    pending: Arc<DashMap<String, oneshot::Sender<Value>>>,
}

impl Kernel {
    pub async fn launch(spec: KernelSpec, cwd: Option<PathBuf>) -> Result<Self> {
        Self::launch_with_timeout(spec, cwd, STARTUP_TIMEOUT).await
    }

    async fn launch_with_timeout(
        spec: KernelSpec,
        cwd: Option<PathBuf>,
        startup_timeout: Duration,
    ) -> Result<Self> {
        let own_ports = binds_own_ports(&spec);
        let conn = if own_ports {
            ConnectionInfo::unbound(&spec.name)
        } else {
            ConnectionInfo::new_localhost(&spec.name)?
        };
        // Removed again when this function fails, or with the kernel.
        let conn_file = ConnectionFile::create(&std::env::temp_dir(), &conn)?;
        let conn_path = conn_file.path.clone();
        tracing::info!(?conn_path, kernel = %spec.name, own_ports, "launching kernel");

        let argv: Vec<String> = spec
            .argv
            .iter()
            .map(|a| {
                a.replace("{connection_file}", conn_path.to_string_lossy().as_ref())
                    .replace("{resource_dir}", spec.path.to_string_lossy().as_ref())
            })
            .collect();

        if argv.is_empty() {
            return Err(anyhow!("kernel '{}' has empty argv", spec.name));
        }

        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..]);
        for (k, v) in &spec.env {
            cmd.env(k, v);
        }
        // Like jupyter_client on Unix: with this pid ipykernel polls its
        // parent and exits once it is gone, so a backend killed by a signal
        // (which skips kill_on_drop) need not leave the kernel running. Only
        // if the poller saw the backend as the parent: older ipykernel, or a
        // backend that died before the poller started, only exit when the
        // kernel is re-parented to PID 1, and a forwarding wrapper keeps it.
        // Set after the kernelspec's env, which cannot override it. Not on
        // Windows: there ipykernel waits on the value as an inheritable
        // process handle, which jupyter_client creates for it; a pid is not
        // one.
        if cfg!(unix) {
            cmd.env("JPY_PARENT_PID", std::process::id().to_string());
        }
        if let Some(d) = cwd {
            cmd.current_dir(d);
        }
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawning {:?}", argv))?;
        let session = Uuid::new_v4().to_string();

        // Nothing else reads the kernel's stdout/stderr: drain them so a chatty
        // kernel cannot block on a full pipe, and keep the end of stderr to
        // explain a failed start.
        let stderr_tail = OutputTail::default();
        if let Some(stdout) = child.stdout.take() {
            tokio::spawn(drain_output(stdout, spec.name.clone(), "stdout", None));
        }
        let stderr_drained = child.stderr.take().map(|stderr| {
            tokio::spawn(drain_output(
                stderr,
                spec.name.clone(),
                "stderr",
                Some(stderr_tail.clone()),
            ))
        });

        // zeromq's connect() retries refused connections forever, so a kernel
        // that dies or never binds its ports would hang here. Race the
        // connection against the kernel exiting and a deadline; on failure the
        // child is dropped, which kills it (kill_on_drop).
        let connect = async {
            let conn = if own_ports {
                read_bound_ports(&conn_path, &conn).await?
            } else {
                conn.clone()
            };
            let sockets = connect_sockets(&conn).await?;
            anyhow::Ok((conn, sockets))
        };
        let (conn, (shell, control, iopub)) = tokio::select! {
            connected = connect => {
                connected.map_err(|e| anyhow!("{e:#}{}", format_tail(&stderr_tail)))?
            }
            status = child.wait() => {
                if let Some(drained) = stderr_drained {
                    // The pipe closes with the process; wait for its last lines.
                    let _ = tokio::time::timeout(Duration::from_secs(1), drained).await;
                }
                let status = match status {
                    Ok(status) => status.to_string(),
                    Err(e) => e.to_string(),
                };
                return Err(anyhow!(
                    "kernel '{}' exited during startup ({status}){}",
                    spec.name,
                    format_tail(&stderr_tail)
                ));
            }
            _ = tokio::time::sleep(startup_timeout) => {
                let what = if own_ports {
                    "write the ports it bound to its connection file"
                } else {
                    "open its ports"
                };
                return Err(anyhow!(
                    "kernel '{}' did not {what} within {startup_timeout:?}{}",
                    spec.name,
                    format_tail(&stderr_tail)
                ));
            }
        };

        let (tx, rx) = mpsc::unbounded_channel::<KernelEvent>();
        let tx_iopub = tx.clone();
        let tx_shell = tx.clone();
        let key = conn.key.as_bytes().to_vec();
        let iopub_handle = tokio::spawn(iopub_loop(iopub, key.clone(), tx_iopub));

        // Single owner per shell/control: tokio::select on outgoing channel + socket recv
        let (shell_tx, shell_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let (control_tx, control_rx) = mpsc::unbounded_channel::<ZmqMessage>();
        let pending: Arc<DashMap<String, oneshot::Sender<Value>>> = Arc::new(DashMap::new());
        tokio::spawn(socket_owner(
            shell,
            shell_rx,
            key.clone(),
            tx_shell,
            "shell",
            Some(pending.clone()),
        ));
        let child = Arc::new(Mutex::new(child));
        let killed = Arc::new(AtomicBool::new(false));
        tokio::spawn(watch_exit(
            Arc::downgrade(&child),
            killed.clone(),
            stderr_tail,
            tx.clone(),
        ));
        let _ = tokio::spawn(socket_owner(control, control_rx, key, tx, "control", None));

        Ok(Self {
            spec,
            conn,
            _conn_file: conn_file,
            session,
            child,
            killed,
            shell_tx,
            control_tx,
            iopub_handle,
            events: Mutex::new(Some(rx)),
            pending,
        })
    }

    pub fn spec(&self) -> &KernelSpec {
        &self.spec
    }
    pub fn session(&self) -> &str {
        &self.session
    }

    /// Move the events receiver out. Returns None if already taken.
    pub async fn take_events(&self) -> Option<mpsc::UnboundedReceiver<KernelEvent>> {
        self.events.lock().await.take()
    }

    /// Send `execute_request`. Returns the msg_id that's already known BEFORE
    /// the bytes hit the wire — so callers can register routing tables before
    /// iopub events start coming back.
    pub async fn execute(&self, code: &str) -> Result<String> {
        self.execute_with_id(code, Uuid::new_v4().to_string()).await
    }

    /// Same as `execute`, but the msg_id is provided externally — handy for
    /// pre-registering msg_id → cell_id BEFORE the request goes out, avoiding
    /// the race where iopub events arrive before the routing map is updated.
    pub async fn execute_with_id(&self, code: &str, msg_id: String) -> Result<String> {
        self.execute_with_id_opts(code, msg_id, false, true).await
    }

    /// `execute_with_id` with explicit silent and store_history flags.
    /// silent=true tells the kernel not to broadcast iopub results AND
    /// not to increment the execution counter. store_history=false also
    /// keeps the run out of Out[N] cache.
    pub async fn execute_with_id_opts(
        &self,
        code: &str,
        msg_id: String,
        silent: bool,
        store_history: bool,
    ) -> Result<String> {
        let mut msg = Message::new(
            "execute_request",
            self.session.clone(),
            protocol::execute_request(code, silent, store_history),
        );
        msg.header.msg_id = msg_id.clone();
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        let zmsg = frames_to_zmq(frames);
        self.shell_tx
            .send(zmsg)
            .map_err(|_| anyhow!("shell channel closed"))?;
        Ok(msg_id)
    }

    /// Send `complete_request` and await the kernel's `complete_reply`.
    /// Returns the reply content as JSON: `{matches, cursor_start, cursor_end,
    /// metadata, status}`. Times out at 2s.
    pub async fn complete(&self, code: &str, cursor_pos: usize) -> Result<Value> {
        self.shell_request(
            "complete_request",
            json!({ "code": code, "cursor_pos": cursor_pos }),
        )
        .await
    }

    /// Send `inspect_request` and await the kernel's `inspect_reply`.
    /// Returns `{status, found, data, metadata}`. detail_level 0 = brief, 1 = full.
    pub async fn inspect(&self, code: &str, cursor_pos: usize, detail_level: u8) -> Result<Value> {
        self.shell_request(
            "inspect_request",
            json!({ "code": code, "cursor_pos": cursor_pos, "detail_level": detail_level }),
        )
        .await
    }

    /// Send a shell-channel request that expects a single reply (not iopub
    /// events). Registers a oneshot in `pending` keyed by msg_id BEFORE the
    /// frame goes out, so the socket owner can route the reply directly.
    async fn shell_request(&self, msg_type: &'static str, content: Value) -> Result<Value> {
        let msg_id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending.insert(msg_id.clone(), tx);

        let mut msg = Message::new(msg_type, self.session.clone(), content);
        msg.header.msg_id = msg_id.clone();
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        let zmsg = frames_to_zmq(frames);
        if self.shell_tx.send(zmsg).is_err() {
            self.pending.remove(&msg_id);
            return Err(anyhow!("shell channel closed"));
        }

        match tokio::time::timeout(Duration::from_millis(2000), rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => {
                self.pending.remove(&msg_id);
                Err(anyhow!("{msg_type} reply dropped"))
            }
            Err(_) => {
                self.pending.remove(&msg_id);
                Err(anyhow!("{msg_type} timed out"))
            }
        }
    }

    pub async fn kernel_info(&self) -> Result<()> {
        let msg = Message::new(
            "kernel_info_request",
            self.session.clone(),
            protocol::kernel_info_request(),
        );
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        self.shell_tx
            .send(frames_to_zmq(frames))
            .map_err(|_| anyhow!("shell closed"))?;
        Ok(())
    }

    pub async fn interrupt(&self) -> Result<()> {
        let msg = Message::new(
            "interrupt_request",
            self.session.clone(),
            protocol::interrupt_request(),
        );
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        self.control_tx
            .send(frames_to_zmq(frames))
            .map_err(|_| anyhow!("control closed"))?;
        Ok(())
    }

    pub async fn shutdown(&self, restart: bool) -> Result<()> {
        let msg = Message::new(
            "shutdown_request",
            self.session.clone(),
            protocol::shutdown_request(restart),
        );
        let key = self.conn.key.as_bytes();
        let frames = msg.to_frames(key)?;
        self.control_tx
            .send(frames_to_zmq(frames))
            .map_err(|_| anyhow!("control closed"))?;
        Ok(())
    }

    pub async fn kill(&self) -> Result<()> {
        self.killed.store(true, Ordering::SeqCst);
        self.iopub_handle.abort();
        let mut child = self.child.lock().await;
        let _ = child.start_kill();
        let _ = child.wait().await;
        Ok(())
    }
}

/// Report a kernel process that exits by itself (a crash, an out-of-memory
/// kill, `os._exit`): its sockets give no sign of it, so the cells it was
/// running would stay busy forever. Exits caused by `Kernel::kill` are not
/// reported. Only a weak reference is held, so dropping the kernel still
/// drops (and kills) its process.
async fn watch_exit(
    child: Weak<Mutex<Child>>,
    killed: Arc<AtomicBool>,
    stderr_tail: OutputTail,
    tx: mpsc::UnboundedSender<KernelEvent>,
) {
    loop {
        tokio::time::sleep(EXIT_POLL_INTERVAL).await;
        let Some(child) = child.upgrade() else {
            return;
        };
        let status = child.lock().await.try_wait();
        match status {
            Ok(None) => {}
            Ok(Some(status)) => {
                if !killed.load(Ordering::SeqCst) {
                    tracing::warn!("kernel exited by itself: {status}");
                    let _ = tx.send(KernelEvent::Exited {
                        status: status.to_string(),
                        stderr: format_tail(&stderr_tail),
                    });
                }
                return;
            }
            Err(e) => {
                tracing::warn!("cannot check the kernel process: {e}");
                return;
            }
        }
    }
}

/// Log a kernel output pipe line by line until it closes. With `tail`, also
/// keep its last lines for error messages.
async fn drain_output(
    mut pipe: impl AsyncRead + Unpin,
    kernel: String,
    stream: &'static str,
    tail: Option<OutputTail>,
) {
    let emit = |line: &[u8]| {
        let text = line_text(line);
        tracing::info!(kernel = %kernel, stream, "{text}");
        if let Some(tail) = &tail {
            let mut tail = tail.lock();
            if tail.lines.len() == STDERR_TAIL_LINES {
                tail.lines.pop_front();
            }
            tail.lines.push_back(text);
            tail.partial.clear();
        }
    };

    let mut buf = [0u8; 8192];
    let mut line = Vec::new();
    loop {
        let n = match pipe.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        for &byte in &buf[..n] {
            if byte == b'\n' {
                emit(&line);
                line.clear();
            } else if line.len() < MAX_LINE_BYTES {
                line.push(byte);
            }
        }
        // Keep the line still being written, so an error reported before it
        // ends (a start that times out) can show it.
        if let Some(tail) = &tail {
            tail.lock().partial = line_text(&line);
        }
    }
    if !line.is_empty() {
        emit(&line);
    }
}

fn format_tail(tail: &OutputTail) -> String {
    let tail = tail.lock();
    let mut lines: Vec<&str> = tail.lines.iter().map(String::as_str).collect();
    if !tail.partial.is_empty() {
        lines.push(&tail.partial);
    }
    if lines.is_empty() {
        return String::new();
    }
    format!("; stderr:\n{}", lines.join("\n"))
}

/// A kernel's connection file. It holds the key that signs messages to the
/// kernel, so whoever can read it can run code in that kernel. It is written
/// into a new directory with an unpredictable name that only this user can
/// enter (a shared /tmp on Linux), readable by the owner only, and both are
/// removed when this value is dropped: with the kernel, or when it fails to
/// start.
struct ConnectionFile {
    dir: PathBuf,
    path: PathBuf,
}

impl ConnectionFile {
    fn create(parent: &Path, conn: &ConnectionInfo) -> Result<Self> {
        let dir = parent.join(format!("notebook_style-{}", Uuid::new_v4()));
        create_private_dir(&dir).with_context(|| format!("creating {}", dir.display()))?;
        let file = Self {
            path: dir.join("kernel.json"),
            dir,
        };
        let contents = serde_json::to_vec_pretty(&json!({
            "ip": conn.ip,
            "transport": conn.transport,
            "shell_port": conn.shell_port,
            "iopub_port": conn.iopub_port,
            "stdin_port": conn.stdin_port,
            "control_port": conn.control_port,
            "hb_port": conn.hb_port,
            "key": conn.key,
            "signature_scheme": conn.signature_scheme,
            "kernel_name": conn.kernel_name,
        }))?;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        options
            .open(&file.path)
            .and_then(|mut f| f.write_all(&contents))
            .with_context(|| format!("writing {}", file.path.display()))?;
        Ok(file)
    }
}

impl Drop for ConnectionFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_dir(&self.dir);
    }
}

#[cfg(unix)]
fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().mode(0o700).create(dir)
}

#[cfg(not(unix))]
fn create_private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir(dir)
}

/// Wait until the kernel has written the ports it bound into its connection
/// file, and return `conn` with those ports. ipykernel writes the file with
/// jupyter_client's secure_write, which removes it and writes it anew, so it
/// can briefly be missing, empty or partly written: all of that means "not
/// yet". A complete file with a different key is an error. Kernel::launch
/// bounds the wait.
async fn read_bound_ports(path: &Path, conn: &ConnectionInfo) -> Result<ConnectionInfo> {
    loop {
        if let Some(written) = tokio::fs::read(path)
            .await
            .ok()
            .and_then(|text| serde_json::from_slice::<Value>(&text).ok())
        {
            if written
                .get("key")
                .and_then(|k| k.as_str())
                .is_some_and(|k| k != conn.key)
            {
                return Err(anyhow!("the kernel's connection file has a different key"));
            }
            let port = |name: &str| {
                written
                    .get(name)
                    .and_then(|p| p.as_u64())
                    .and_then(|p| u16::try_from(p).ok())
                    .filter(|p| *p != 0)
            };
            if let (Some(shell), Some(iopub), Some(stdin), Some(control), Some(hb)) = (
                port("shell_port"),
                port("iopub_port"),
                port("stdin_port"),
                port("control_port"),
                port("hb_port"),
            ) {
                return Ok(ConnectionInfo {
                    shell_port: shell,
                    iopub_port: iopub,
                    stdin_port: stdin,
                    control_port: control,
                    hb_port: hb,
                    ..conn.clone()
                });
            }
        }
        tokio::time::sleep(PORT_POLL_INTERVAL).await;
    }
}

async fn connect_sockets(conn: &ConnectionInfo) -> Result<(DealerSocket, DealerSocket, SubSocket)> {
    let mut attempt = 1;
    loop {
        wait_for_ports(conn).await;
        match connect_once(conn).await {
            Ok(sockets) => return Ok(sockets),
            // The ports were open when probed, yet connecting failed: the
            // ports are picked by binding to port 0 and released before the
            // kernel binds them, so something else can briefly hold one.
            Err(e) if attempt < CONNECT_ATTEMPTS => {
                tracing::info!("connecting to the kernel failed, trying again: {e:#}");
                attempt += 1;
                tokio::time::sleep(PORT_POLL_INTERVAL).await;
            }
            Err(e) => return Err(e),
        }
    }
}

/// Wait until the kernel's shell, control and iopub ports accept TCP
/// connections. zeromq's connect() retries a refused connection only after a
/// back-off (the first retry comes ~1.4 s later), while a kernel typically
/// opens its ports within a few hundred milliseconds; polling lets the
/// connect that follows succeed at once. Kernel::launch bounds this wait.
async fn wait_for_ports(conn: &ConnectionInfo) {
    for port in [conn.shell_port, conn.control_port, conn.iopub_port] {
        while tokio::net::TcpStream::connect((conn.ip.as_str(), port))
            .await
            .is_err()
        {
            tokio::time::sleep(PORT_POLL_INTERVAL).await;
        }
    }
}

async fn connect_once(conn: &ConnectionInfo) -> Result<(DealerSocket, DealerSocket, SubSocket)> {
    let mut shell = DealerSocket::new();
    let mut control = DealerSocket::new();
    let mut iopub = SubSocket::new();
    iopub
        .subscribe("")
        .await
        .map_err(|e| anyhow!("iopub subscribe: {e}"))?;
    shell
        .connect(&conn.endpoint(conn.shell_port))
        .await
        .map_err(|e| anyhow!("shell connect: {e}"))?;
    control
        .connect(&conn.endpoint(conn.control_port))
        .await
        .map_err(|e| anyhow!("control connect: {e}"))?;
    iopub
        .connect(&conn.endpoint(conn.iopub_port))
        .await
        .map_err(|e| anyhow!("iopub connect: {e}"))?;
    Ok((shell, control, iopub))
}

/// Owns a DEALER socket. Drains an outgoing channel and recv()s replies.
/// Replies are parsed and forwarded as ExecuteReply (or other shell-side msg).
async fn socket_owner(
    mut sock: DealerSocket,
    mut out_rx: mpsc::UnboundedReceiver<ZmqMessage>,
    key: Vec<u8>,
    tx: mpsc::UnboundedSender<KernelEvent>,
    label: &'static str,
    pending: Option<Arc<DashMap<String, oneshot::Sender<Value>>>>,
) {
    loop {
        tokio::select! {
            biased; // prefer sends so outgoing isn't starved by recv
            out = out_rx.recv() => {
                match out {
                    Some(zmsg) => {
                        if let Err(e) = sock.send(zmsg).await {
                            tracing::warn!("{label} send: {e}");
                        }
                    }
                    None => {
                        tracing::info!("{label} outgoing channel closed; owner exit");
                        return;
                    }
                }
            }
            recv = sock.recv() => {
                match recv {
                    Ok(zmsg) => {
                        let frames = zmq_to_frames(zmsg);
                        match Message::from_frames(frames, &key) {
                            Ok(reply) => {
                                let parent = reply
                                    .parent_header
                                    .get("msg_id")
                                    .and_then(|v| v.as_str())
                                    .map(|s| s.to_string());
                                // If a caller is awaiting this msg_id (complete_request,
                                // inspect_request, etc.), deliver the content directly
                                // via the oneshot and skip the events-channel path.
                                if let (Some(map), Some(pid)) = (pending.as_ref(), parent.as_ref()) {
                                    if let Some((_, sender)) = map.remove(pid) {
                                        let _ = sender.send(reply.content);
                                        continue;
                                    }
                                }
                                let status = reply
                                    .content
                                    .get("status")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("unknown")
                                    .to_string();
                                let exec_count = reply
                                    .content
                                    .get("execution_count")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(0);
                                if reply.header.msg_type == "kernel_info_reply" {
                                    let _ = tx.send(KernelEvent::KernelInfo {
                                        parent_msg_id: parent,
                                        info: reply.content,
                                    });
                                } else {
                                    let _ = tx.send(KernelEvent::ExecuteReply {
                                        parent_msg_id: parent,
                                        status,
                                        execution_count: exec_count,
                                    });
                                }
                            }
                            Err(e) => tracing::warn!("{label} reply parse: {e}"),
                        }
                    }
                    Err(e) => {
                        tracing::warn!("{label} recv error: {e}");
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                }
            }
        }
    }
}

async fn iopub_loop(mut sock: SubSocket, key: Vec<u8>, tx: mpsc::UnboundedSender<KernelEvent>) {
    loop {
        match sock.recv().await {
            Ok(zmsg) => {
                let frames = zmq_to_frames(zmsg);
                match Message::from_frames(frames, &key) {
                    Ok(msg) => {
                        let parent = msg
                            .parent_header
                            .get("msg_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        tracing::info!("iopub recv type={} parent={}", msg.header.msg_type, parent);
                        if let Some(ev) = iopub_to_event(&msg) {
                            if tx.send(ev).is_err() {
                                tracing::info!("iopub event channel closed; iopub loop exit");
                                return;
                            }
                        } else {
                            tracing::info!(
                                "iopub: no event mapping for type {}",
                                msg.header.msg_type
                            );
                        }
                    }
                    Err(e) => tracing::warn!("iopub parse: {e}"),
                }
            }
            Err(e) => {
                tracing::warn!("iopub recv: {e}");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

fn iopub_to_event(msg: &Message) -> Option<KernelEvent> {
    let parent = msg
        .parent_header
        .get("msg_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let msg_id = msg.header.msg_id.clone();
    let c = &msg.content;
    match msg.header.msg_type.as_str() {
        "stream" => Some(KernelEvent::Stream {
            msg_id,
            parent_msg_id: parent,
            name: c
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("stdout")
                .to_string(),
            text: c
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        }),
        "display_data" => Some(KernelEvent::DisplayData {
            msg_id,
            parent_msg_id: parent,
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
            transient: c.get("transient").cloned().unwrap_or(json!({})),
        }),
        "update_display_data" => Some(KernelEvent::UpdateDisplayData {
            msg_id,
            parent_msg_id: parent,
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
            transient: c.get("transient").cloned().unwrap_or(json!({})),
        }),
        "execute_result" => Some(KernelEvent::ExecuteResult {
            msg_id,
            parent_msg_id: parent,
            execution_count: c
                .get("execution_count")
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            data: c.get("data").cloned().unwrap_or(json!({})),
            metadata: c.get("metadata").cloned().unwrap_or(json!({})),
        }),
        "error" => Some(KernelEvent::Error {
            msg_id,
            parent_msg_id: parent,
            ename: c
                .get("ename")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            evalue: c
                .get("evalue")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            traceback: c
                .get("traceback")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|t| t.as_str().map(|s| s.to_string()))
                        .collect()
                })
                .unwrap_or_default(),
        }),
        "status" => Some(KernelEvent::Status {
            execution_state: c
                .get("execution_state")
                .and_then(|v| v.as_str())
                .unwrap_or("idle")
                .to_string(),
            parent_msg_id: parent,
        }),
        "execute_input" => Some(KernelEvent::ExecuteInput {
            parent_msg_id: parent,
            execution_count: c
                .get("execution_count")
                .and_then(|v| v.as_u64())
                .unwrap_or(0),
            code: c
                .get("code")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        }),
        "clear_output" => Some(KernelEvent::ClearOutput {
            parent_msg_id: parent,
            wait: c.get("wait").and_then(|v| v.as_bool()).unwrap_or(false),
        }),
        _ => None,
    }
}

fn frames_to_zmq(frames: Vec<Bytes>) -> ZmqMessage {
    let mut iter = frames.into_iter();
    let first = iter.next().unwrap_or_default();
    let mut zmsg = ZmqMessage::from(first);
    for f in iter {
        zmsg.push_back(f);
    }
    zmsg
}

fn zmq_to_frames(zmsg: ZmqMessage) -> Vec<Bytes> {
    zmsg.into_vec()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// Tests that pick ports or start processes run one at a time. Ports are
    /// picked by binding to port 0 and releasing them, so tests running in
    /// parallel can be handed ports another test is about to use; the
    /// latency test also needs a quiet machine.
    fn serial() -> std::sync::MutexGuard<'static, ()> {
        static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
        SERIAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn spec(argv: &[&str]) -> KernelSpec {
        KernelSpec {
            name: "test-kernel".to_string(),
            path: std::env::temp_dir(),
            argv: argv.iter().map(|arg| arg.to_string()).collect(),
            display_name: "Test kernel".to_string(),
            language: "python".to_string(),
            interrupt_mode: None,
            env: HashMap::new(),
            metadata: Value::Null,
        }
    }

    /// Launch with a bound, so a regression shows up as a failure, not a hang.
    async fn launch_error(spec: KernelSpec, startup_timeout: Duration) -> String {
        let launched = tokio::time::timeout(
            Duration::from_secs(10),
            Kernel::launch_with_timeout(spec, None, startup_timeout),
        )
        .await
        .expect("kernel launch must not hang");
        match launched {
            Ok(_) => panic!("the kernel must not start"),
            Err(e) => format!("{e:#}"),
        }
    }

    #[tokio::test]
    async fn launch_reports_a_kernel_that_exits_during_startup() {
        let _serial = serial();
        let message = launch_error(
            spec(&[
                "sh",
                "-c",
                "echo 'No module named ipykernel_launcher' >&2; exit 3",
            ]),
            STARTUP_TIMEOUT,
        )
        .await;
        assert!(message.contains("exited during startup"), "{message}");
        assert!(message.contains("exit status: 3"), "{message}");
        assert!(
            message.contains("No module named ipykernel_launcher"),
            "{message}"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn launch_tells_the_kernel_its_parent_pid() {
        let _serial = serial();
        let expected = format!("parent={}", std::process::id());
        // Also when the kernelspec's env sets the variable: ours wins.
        for preset in [None, Some("preset-by-the-kernelspec")] {
            let mut kernel = spec(&["sh", "-c", "echo \"parent=$JPY_PARENT_PID\" >&2; exit 3"]);
            if let Some(value) = preset {
                kernel
                    .env
                    .insert("JPY_PARENT_PID".to_string(), value.to_string());
            }
            let message = launch_error(kernel, STARTUP_TIMEOUT).await;
            assert!(message.contains(&expected), "{preset:?}: {message}");
        }
    }

    #[tokio::test]
    async fn connect_sockets_follows_a_late_kernel_promptly() {
        let _serial = serial();
        let conn = ConnectionInfo::new_localhost("late-kernel").unwrap();
        let ports = conn.clone();
        // Stands in for a kernel that opens its ports shortly after launch.
        let kernel = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            let mut shell = zeromq::RouterSocket::new();
            shell.bind(&ports.endpoint(ports.shell_port)).await.unwrap();
            let mut control = zeromq::RouterSocket::new();
            control
                .bind(&ports.endpoint(ports.control_port))
                .await
                .unwrap();
            let mut iopub = zeromq::PubSocket::new();
            iopub.bind(&ports.endpoint(ports.iopub_port)).await.unwrap();
            tokio::time::sleep(Duration::from_secs(10)).await;
            drop((shell, control, iopub));
        });

        let started = std::time::Instant::now();
        let connected = tokio::time::timeout(Duration::from_secs(10), connect_sockets(&conn)).await;
        let elapsed = started.elapsed();
        kernel.abort();
        connected
            .expect("connect must not hang")
            .expect("connect must succeed");
        // zeromq's own retry would only connect after ~1.4 s.
        assert!(
            elapsed < Duration::from_millis(800),
            "connected after {elapsed:?}"
        );
    }

    fn watcher(
        child: &Arc<Mutex<Child>>,
        killed: &Arc<AtomicBool>,
        tail: OutputTail,
    ) -> (
        tokio::task::JoinHandle<()>,
        mpsc::UnboundedReceiver<KernelEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        let handle = tokio::spawn(watch_exit(Arc::downgrade(child), killed.clone(), tail, tx));
        (handle, rx)
    }

    #[tokio::test]
    async fn watch_exit_reports_a_kernel_that_exits_by_itself() {
        let _serial = serial();
        let mut child = Command::new("sh")
            .args(["-c", "echo 'Fatal Python error: boom' >&2; exit 7"])
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let tail = OutputTail::default();
        let stderr = child.stderr.take().unwrap();
        drain_output(stderr, "test".to_string(), "stderr", Some(tail.clone())).await;
        let child = Arc::new(Mutex::new(child));
        let (handle, mut rx) = watcher(&child, &Arc::new(AtomicBool::new(false)), tail);
        let event = tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("the exit must be reported")
            .expect("the watcher must send an event");
        match event {
            KernelEvent::Exited { status, stderr } => {
                assert!(status.contains('7'), "{status}");
                assert!(stderr.contains("Fatal Python error: boom"), "{stderr}");
            }
            other => panic!("unexpected event {other:?}"),
        }
        handle.await.unwrap();
    }

    #[tokio::test]
    async fn watch_exit_does_not_report_a_kill() {
        let _serial = serial();
        let child = Arc::new(Mutex::new(Command::new("sleep").arg("30").spawn().unwrap()));
        let killed = Arc::new(AtomicBool::new(false));
        let (handle, mut rx) = watcher(&child, &killed, OutputTail::default());
        // What Kernel::kill does.
        killed.store(true, Ordering::SeqCst);
        {
            let mut child = child.lock().await;
            child.start_kill().unwrap();
            child.wait().await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("the watcher must stop")
            .unwrap();
        assert!(rx.try_recv().is_err(), "a kill must not be reported");
    }

    #[tokio::test]
    async fn watch_exit_stops_with_its_kernel() {
        let _serial = serial();
        let child = Arc::new(Mutex::new(
            Command::new("sleep")
                .arg("30")
                .kill_on_drop(true)
                .spawn()
                .unwrap(),
        ));
        let (handle, mut rx) = watcher(
            &child,
            &Arc::new(AtomicBool::new(false)),
            OutputTail::default(),
        );
        drop(child);
        tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("the watcher must stop")
            .unwrap();
        assert!(rx.try_recv().is_err());
    }

    #[cfg(unix)]
    #[test]
    fn connection_files_are_private_and_removed_when_dropped() {
        let _serial = serial();
        use std::os::unix::fs::PermissionsExt;
        let conn = ConnectionInfo::new_localhost("test-kernel").unwrap();
        let file = ConnectionFile::create(&std::env::temp_dir(), &conn).unwrap();
        let (dir, path) = (file.dir.clone(), file.path.clone());
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700, "{}", dir.display());
        assert_eq!(mode(&path), 0o600, "{}", path.display());
        let written: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(written["key"], conn.key.as_str());
        assert_eq!(written["shell_port"], conn.shell_port);
        drop(file);
        assert!(!path.exists(), "{} must be removed", path.display());
        assert!(!dir.exists(), "{} must be removed", dir.display());
    }

    #[tokio::test]
    async fn a_kernel_that_fails_to_start_leaves_no_connection_file() {
        let _serial = serial();
        let message = launch_error(
            spec(&[
                "sh",
                "-c",
                "echo \"connection=$0\" >&2; exit 3",
                "{connection_file}",
            ]),
            STARTUP_TIMEOUT,
        )
        .await;
        let path = message
            .split("connection=")
            .nth(1)
            .and_then(|rest| rest.lines().next())
            .unwrap_or_else(|| panic!("no connection file path in: {message}"));
        let path = Path::new(path.trim());
        assert!(path.ends_with("kernel.json"), "{message}");
        assert!(!path.exists(), "{} must be removed", path.display());
        assert!(!path.parent().unwrap().exists(), "{message}");
    }

    #[tokio::test]
    async fn connect_sockets_retries_when_something_else_held_a_port() {
        let _serial = serial();
        let conn = ConnectionInfo::new_localhost("squatted-kernel").unwrap();
        let ports = conn.clone();
        let kernel = tokio::spawn(async move {
            let mut control = zeromq::RouterSocket::new();
            control
                .bind(&ports.endpoint(ports.control_port))
                .await
                .unwrap();
            let mut iopub = zeromq::PubSocket::new();
            iopub.bind(&ports.endpoint(ports.iopub_port)).await.unwrap();
            // Another process briefly holds the shell port: it accepts the
            // port probe and the first connection, closes them and goes away.
            let squatter = tokio::net::TcpListener::bind((ports.ip.as_str(), ports.shell_port))
                .await
                .unwrap();
            for _ in 0..2 {
                let (stream, _) = squatter.accept().await.unwrap();
                drop(stream);
            }
            drop(squatter);
            let mut shell = zeromq::RouterSocket::new();
            shell.bind(&ports.endpoint(ports.shell_port)).await.unwrap();
            tokio::time::sleep(Duration::from_secs(10)).await;
            drop((shell, control, iopub));
        });

        let connected = tokio::time::timeout(Duration::from_secs(10), connect_sockets(&conn)).await;
        kernel.abort();
        connected
            .expect("connect must not hang")
            .expect("connect must succeed once the kernel holds its ports");
    }

    #[tokio::test]
    async fn launch_shows_stderr_without_a_final_newline_on_timeout() {
        let _serial = serial();
        let message = launch_error(
            spec(&[
                "sh",
                "-c",
                "printf 'startup failure without newline' >&2; exec sleep 30",
            ]),
            Duration::from_millis(500),
        )
        .await;
        assert!(message.contains("did not open its ports"), "{message}");
        assert!(
            message.contains("startup failure without newline"),
            "{message}"
        );
    }

    #[tokio::test]
    async fn launch_drains_a_kernel_that_floods_stdout() {
        let _serial = serial();
        // 2 MB on stdout would fill the pipe and block the kernel if nobody
        // read it; then the start would only fail at the deadline.
        let started = std::time::Instant::now();
        let message = launch_error(
            spec(&[
                "sh",
                "-c",
                "head -c 2000000 /dev/zero | tr '\\0' 'x'; exit 4",
            ]),
            Duration::from_secs(5),
        )
        .await;
        assert!(message.contains("exit status: 4"), "{message}");
        assert!(
            started.elapsed() < Duration::from_secs(4),
            "reported after {:?}",
            started.elapsed()
        );
    }

    #[tokio::test]
    async fn drained_lines_are_cut_at_a_character_boundary() {
        let mut data = vec![b'a'; MAX_LINE_BYTES - 1];
        data.extend_from_slice("€€\n".as_bytes());
        let tail = OutputTail::default();
        drain_output(&data[..], "test".to_string(), "stderr", Some(tail.clone())).await;
        let tail = tail.lock();
        let line = tail.lines.back().expect("one line");
        assert!(line.len() <= MAX_LINE_BYTES, "{} bytes", line.len());
        assert!(line.starts_with("aaa"));
    }

    #[tokio::test]
    async fn launch_gives_up_on_a_kernel_that_never_opens_its_ports() {
        let _serial = serial();
        let message = launch_error(spec(&["sleep", "30"]), Duration::from_millis(500)).await;
        assert!(
            message.contains("did not open its ports within 500ms"),
            "{message}"
        );
    }

    #[test]
    fn only_ipykernel_kernels_bind_their_own_ports() {
        let ipykernel = [
            &[
                "python3",
                "-m",
                "ipykernel_launcher",
                "-f",
                "{connection_file}",
            ][..],
            &[
                "/p/.venv/bin/python",
                "-m",
                "ipykernel",
                "-f",
                "{connection_file}",
            ][..],
            &[
                "/usr/bin/python3.12",
                "-Xfrozen_modules=off",
                "-m",
                "ipykernel_launcher",
                "-f",
                "{connection_file}",
            ][..],
        ];
        for argv in ipykernel {
            assert!(binds_own_ports(&spec(argv)), "{argv:?}");
        }
        let others = [
            &["julia", "-i", "kernel.jl", "{connection_file}"][..],
            &[
                "R",
                "--slave",
                "-e",
                "IRkernel::main()",
                "--args",
                "{connection_file}",
            ][..],
            &["sleep", "30"][..],
            // Wrappers that are handed the file keep the ports picked here.
            &[
                "sh",
                "-c",
                "exec python3 -m ipykernel_launcher -f \"$1\"",
                "sh",
                "{connection_file}",
            ][..],
            &[
                "conda",
                "run",
                "-n",
                "work",
                "python",
                "-m",
                "ipykernel_launcher",
                "-f",
                "{connection_file}",
            ][..],
            &[
                "python3",
                "-m",
                "ssh_ipykernel",
                "--host",
                "remote",
                "-f",
                "{connection_file}",
            ][..],
        ];
        for argv in others {
            assert!(!binds_own_ports(&spec(argv)), "{argv:?}");
        }
    }

    /// The connection file as the kernel would write it, with `ports` in
    /// the order shell, iopub, stdin, control, hb.
    fn written_by_kernel(conn: &ConnectionInfo, key: &str, ports: [u16; 5]) -> Vec<u8> {
        serde_json::to_vec_pretty(&json!({
            "ip": conn.ip,
            "transport": conn.transport,
            "shell_port": ports[0],
            "iopub_port": ports[1],
            "stdin_port": ports[2],
            "control_port": ports[3],
            "hb_port": ports[4],
            "key": key,
            "signature_scheme": conn.signature_scheme,
            "kernel_name": conn.kernel_name,
        }))
        .unwrap()
    }

    #[tokio::test]
    async fn read_bound_ports_waits_for_the_complete_file() {
        let conn = ConnectionInfo::unbound("test-kernel");
        let file = ConnectionFile::create(&std::env::temp_dir(), &conn).unwrap();
        let path = file.path.clone();
        let full = written_by_kernel(&conn, &conn.key, [5101, 5102, 5103, 5104, 5105]);
        // What secure_write leaves on the way: no file, an empty file, part of
        // the JSON, then all of it. The file it started from has ports 0.
        let writer = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(60)).await;
            std::fs::remove_file(&path).unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;
            std::fs::write(&path, b"").unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;
            std::fs::write(&path, &full[..full.len() / 2]).unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;
            std::fs::write(&path, &full).unwrap();
        });
        let bound =
            tokio::time::timeout(Duration::from_secs(5), read_bound_ports(&file.path, &conn))
                .await
                .expect("the ports must be read")
                .expect("the file is valid");
        writer.await.unwrap();
        assert_eq!(
            [
                bound.shell_port,
                bound.iopub_port,
                bound.stdin_port,
                bound.control_port,
                bound.hb_port
            ],
            [5101, 5102, 5103, 5104, 5105]
        );
        assert_eq!(bound.key, conn.key);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn launch_gives_ipykernel_ports_0_and_other_kernels_picked_ports() {
        use std::os::unix::fs::PermissionsExt;
        // Also keeps other tests from forking while the script below is
        // open for writing, which would make running it fail (ETXTBSY).
        let _serial = serial();
        // Stands in for "python -m <module> -f <connection file>": shows the
        // shell port in the file it was given, then exits.
        let dir = std::env::temp_dir().join(format!("notebook-style-test-{}", Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let python = dir.join("python");
        std::fs::write(
            &python,
            "#!/bin/sh\ngrep -o '\"shell_port\": [0-9]*' \"$4\" >&2\nexit 3\n",
        )
        .unwrap();
        std::fs::set_permissions(&python, std::fs::Permissions::from_mode(0o755)).unwrap();
        let python = python.to_str().unwrap();
        let ipykernel = launch_error(
            spec(&[
                python,
                "-m",
                "ipykernel_launcher",
                "-f",
                "{connection_file}",
            ]),
            STARTUP_TIMEOUT,
        )
        .await;
        let other = launch_error(
            spec(&[python, "-m", "other_kernel", "-f", "{connection_file}"]),
            STARTUP_TIMEOUT,
        )
        .await;
        std::fs::remove_dir_all(&dir).unwrap();
        // Exiting before it wrote its ports is reported as an exit.
        assert!(ipykernel.contains("exited during startup"), "{ipykernel}");
        assert!(ipykernel.contains("\"shell_port\": 0"), "{ipykernel}");
        assert!(other.contains("\"shell_port\": "), "{other}");
        assert!(!other.contains("\"shell_port\": 0"), "{other}");
    }

    #[tokio::test]
    async fn read_bound_ports_rejects_a_file_with_another_key() {
        let conn = ConnectionInfo::unbound("test-kernel");
        let file = ConnectionFile::create(&std::env::temp_dir(), &conn).unwrap();
        std::fs::write(
            &file.path,
            written_by_kernel(&conn, "not-our-key", [5101, 5102, 5103, 5104, 5105]),
        )
        .unwrap();
        let result =
            tokio::time::timeout(Duration::from_secs(5), read_bound_ports(&file.path, &conn))
                .await
                .expect("must not wait");
        assert!(result.is_err(), "{result:?}");
    }
}
