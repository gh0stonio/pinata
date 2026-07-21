use base64::{engine::general_purpose::STANDARD, Engine as _};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Mutex,
    thread,
};
use tauri::{AppHandle, Emitter, Event, Manager, State};

const TERMINAL_OUTPUT_EVENT: &str = "pinata://terminal-output";
const TERMINAL_EXIT_EVENT: &str = "pinata://terminal-exit";
pub const TERMINAL_INPUT_EVENT: &str = "pinata://terminal-input";
const TMUX_SESSION_PREFIX: &str = "pinata";

#[derive(Default)]
pub struct TerminalState {
    attachments: Mutex<HashMap<String, TerminalAttachment>>,
}

struct TerminalAttachment {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSessionInput {
    pub session_id: String,
    pub cwd: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalAttachInput {
    pub session_id: String,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalWriteInput {
    pub session_id: String,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalResizeInput {
    pub session_id: String,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalScrollInput {
    pub session_id: String,
    pub lines: i16,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSessionOnlyInput {
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalOutputEvent {
    session_id: String,
    data: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TerminalExitEvent {
    session_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalProcessStatus {
    busy: bool,
    command: Option<String>,
}

#[tauri::command]
pub fn terminal_ensure_session(app: AppHandle, input: TerminalSessionInput) -> Result<(), String> {
    ensure_session(&app, &input.session_id, &input.cwd)
}

#[tauri::command]
pub fn terminal_shell_name() -> String {
    env::var("SHELL")
        .ok()
        .and_then(|shell| {
            Path::new(&shell)
                .file_name()
                .and_then(|name| name.to_str())
                .map(str::to_owned)
        })
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "shell".into())
}

#[tauri::command]
pub fn terminal_attach(
    app: AppHandle,
    state: State<TerminalState>,
    input: TerminalAttachInput,
) -> Result<(), String> {
    ensure_session(&app, &input.session_id, &input.cwd)?;
    detach_attachment(&state, &input.session_id);

    let tmux = tmux_binary_path(&app)?;
    let socket = tmux_socket_path(&app)?;
    let session_name = tmux_session_name(&input.session_id);
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: input.rows.max(1),
            cols: input.cols.max(1),
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| error.to_string())?;
    let mut command = CommandBuilder::new(tmux);

    command.arg("-f");
    command.arg("/dev/null");
    command.arg("-S");
    command.arg(socket);
    command.arg("attach-session");
    command.arg("-t");
    command.arg(session_name);
    command.env("TERM", "xterm-256color");

    let child = pair
        .slave
        .spawn_command(command)
        .map_err(|error| error.to_string())?;
    drop(pair.slave);

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|error| error.to_string())?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|error| error.to_string())?;
    let session_id = input.session_id.clone();
    let event_session_id = input.session_id.clone();
    let app_for_reader = app.clone();

    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];

        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    let _ = app_for_reader.emit(
                        TERMINAL_OUTPUT_EVENT,
                        TerminalOutputEvent {
                            session_id: event_session_id.clone(),
                            data: STANDARD.encode(&buffer[..count]),
                        },
                    );
                }
                Err(_) => break,
            }
        }

        let _ = app_for_reader.emit(
            TERMINAL_EXIT_EVENT,
            TerminalExitEvent {
                session_id: event_session_id,
            },
        );
    });

    let mut attachments = state
        .attachments
        .lock()
        .map_err(|_| "terminal state is locked".to_string())?;

    attachments.insert(
        session_id,
        TerminalAttachment {
            master: pair.master,
            writer,
            child,
        },
    );

    Ok(())
}

pub fn handle_terminal_input_event(app: AppHandle, event: Event) {
    let Ok(input) = serde_json::from_str::<TerminalWriteInput>(event.payload()) else {
        return;
    };

    let state = app.state::<TerminalState>();
    let _ = write_terminal_input(state.inner(), input);
}

fn write_terminal_input(state: &TerminalState, input: TerminalWriteInput) -> Result<(), String> {
    let mut attachments = state
        .attachments
        .lock()
        .map_err(|_| "terminal state is locked".to_string())?;
    let Some(attachment) = attachments.get_mut(&input.session_id) else {
        return Ok(());
    };

    attachment
        .writer
        .write_all(input.data.as_bytes())
        .map_err(|error| error.to_string())?;
    attachment.writer.flush().map_err(|error| error.to_string())
}

#[tauri::command]
pub fn terminal_resize(
    state: State<TerminalState>,
    input: TerminalResizeInput,
) -> Result<(), String> {
    let attachments = state
        .attachments
        .lock()
        .map_err(|_| "terminal state is locked".to_string())?;
    let Some(attachment) = attachments.get(&input.session_id) else {
        return Ok(());
    };

    attachment
        .master
        .resize(PtySize {
            rows: input.rows.max(1),
            cols: input.cols.max(1),
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn terminal_scroll(app: AppHandle, input: TerminalScrollInput) -> Result<(), String> {
    if input.lines == 0 || !has_session(&app, &input.session_id)? {
        return Ok(());
    }

    let session_name = tmux_session_name(&input.session_id);
    let count = input.lines.unsigned_abs().to_string();

    if input.lines < 0 {
        let status = tmux_command(&app)?
            .args(["copy-mode", "-e", "-t", &session_name])
            .status()
            .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

        if !status.success() {
            return Err("failed to enter terminal scrollback".into());
        }

        send_tmux_copy_mode_command(&app, &session_name, &count, "scroll-up", false)
    } else {
        send_tmux_copy_mode_command(&app, &session_name, &count, "scroll-down", true).or(Ok(()))
    }
}

#[tauri::command]
pub fn terminal_cancel_scroll(
    app: AppHandle,
    input: TerminalSessionOnlyInput,
) -> Result<(), String> {
    if !has_session(&app, &input.session_id)? {
        return Ok(());
    }

    let session_name = tmux_session_name(&input.session_id);
    send_tmux_copy_mode_command(&app, &session_name, "1", "cancel", true).or(Ok(()))
}

#[tauri::command]
pub fn terminal_clear(app: AppHandle, input: TerminalSessionOnlyInput) -> Result<(), String> {
    if !has_session(&app, &input.session_id)? {
        return Ok(());
    }

    let session_name = tmux_session_name(&input.session_id);
    let _ = send_tmux_copy_mode_command(&app, &session_name, "1", "cancel", true);
    let status = tmux_command(&app)?
        .args(["clear-history", "-t", &session_name])
        .status()
        .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

    if status.success() {
        return Ok(());
    }

    Err("failed to clear terminal history".into())
}

#[tauri::command]
pub fn terminal_detach(
    state: State<TerminalState>,
    input: TerminalSessionOnlyInput,
) -> Result<(), String> {
    detach_attachment(&state, &input.session_id);
    Ok(())
}

#[tauri::command]
pub fn terminal_kill_session(
    app: AppHandle,
    state: State<TerminalState>,
    input: TerminalSessionOnlyInput,
) -> Result<(), String> {
    detach_attachment(&state, &input.session_id);

    if !has_session(&app, &input.session_id)? {
        return Ok(());
    }

    let status = tmux_command(&app)?
        .args(["kill-session", "-t", &tmux_session_name(&input.session_id)])
        .status()
        .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

    if status.success() {
        return Ok(());
    }

    Err("failed to kill terminal session".into())
}

#[tauri::command]
pub fn terminal_process_status(
    app: AppHandle,
    input: TerminalSessionOnlyInput,
) -> Result<TerminalProcessStatus, String> {
    if !has_session(&app, &input.session_id)? {
        return Ok(TerminalProcessStatus {
            busy: false,
            command: None,
        });
    }

    let output = tmux_command(&app)?
        .args([
            "display-message",
            "-p",
            "-t",
            &tmux_session_name(&input.session_id),
            "#{pane_current_command}\t#{pane_tty}",
        ])
        .output()
        .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

    if !output.status.success() {
        return Err("failed to inspect terminal process".into());
    }

    let status = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let (current_command, pane_tty) = status
        .split_once('\t')
        .map(|(command, tty)| (command.trim(), tty.trim()))
        .unwrap_or((status.trim(), ""));
    let command = foreground_command_for_tty(pane_tty)
        .or_else(|| command_label(current_command, current_command));
    let busy = command
        .as_deref()
        .is_some_and(|command| !is_idle_terminal_command(command));

    Ok(TerminalProcessStatus { busy, command })
}

fn foreground_command_for_tty(tty_path: &str) -> Option<String> {
    let tty = Path::new(tty_path).file_name()?.to_str()?;
    let output = Command::new("ps")
        .args(["-t", tty, "-o", "pid=,ppid=,stat=,comm=,command="])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    foreground_command_from_ps_output(&String::from_utf8_lossy(&output.stdout))
}

fn foreground_command_from_ps_output(output: &str) -> Option<String> {
    let processes = output
        .lines()
        .filter_map(parse_ps_process)
        .filter(|process| process.stat.contains('+'))
        .collect::<Vec<_>>();
    let parent_pids = processes
        .iter()
        .map(|process| process.ppid)
        .collect::<HashSet<_>>();

    processes
        .iter()
        .filter(|process| !parent_pids.contains(&process.pid))
        .filter_map(|process| command_label(&process.comm, &process.command))
        .filter(|command| !is_idle_terminal_command(command))
        .last()
}

struct PsProcess {
    pid: u32,
    ppid: u32,
    stat: String,
    comm: String,
    command: String,
}

fn parse_ps_process(line: &str) -> Option<PsProcess> {
    let mut fields = line.split_whitespace();
    let pid = fields.next()?.parse().ok()?;
    let ppid = fields.next()?.parse().ok()?;
    let stat = fields.next()?.to_string();
    let comm = fields.next()?.to_string();
    let command = fields.collect::<Vec<_>>().join(" ");

    Some(PsProcess {
        pid,
        ppid,
        stat,
        comm,
        command,
    })
}

fn command_label(comm: &str, command: &str) -> Option<String> {
    let comm = command_name(comm);

    if !is_wrapper_command(&comm) && !is_tty_command(&comm) {
        return (!comm.is_empty()).then_some(comm);
    }

    command
        .split_whitespace()
        .map(command_name)
        .find(|name| !name.is_empty() && !is_wrapper_command(name) && !is_tty_command(name))
        .or_else(|| (!comm.is_empty() && !is_tty_command(&comm)).then_some(comm))
}

fn command_name(command: &str) -> String {
    Path::new(command)
        .file_name()
        .and_then(|file_name| file_name.to_str())
        .unwrap_or(command)
        .to_string()
}

fn is_wrapper_command(command: &str) -> bool {
    command.ends_with("-shim")
}

fn is_tty_command(command: &str) -> bool {
    let command = command.strip_prefix("/dev/").unwrap_or(command);

    if let Some(rest) = command.strip_prefix("pts/") {
        return is_digits(rest);
    }

    command
        .strip_prefix("tty")
        .is_some_and(|rest| is_digits(rest) || rest.strip_prefix('s').is_some_and(is_digits))
}

fn is_digits(value: &str) -> bool {
    !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
}

fn ensure_session(app: &AppHandle, session_id: &str, cwd: &str) -> Result<(), String> {
    let cwd = expand_home(cwd.trim())?;

    if !cwd.exists() {
        return Err("terminal working directory does not exist".into());
    }

    if has_session(app, session_id)? {
        return configure_session(app, session_id);
    }

    let shell = default_shell();
    let shell_command = login_shell_command(&shell);
    let status = tmux_command(app)?
        .args([
            "new-session",
            "-d",
            "-s",
            &tmux_session_name(session_id),
            "-c",
            cwd.to_str()
                .ok_or_else(|| "terminal working directory is not valid UTF-8".to_string())?,
            &shell_command,
        ])
        .status()
        .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

    if status.success() {
        return configure_session(app, session_id);
    }

    Err("failed to create terminal session".into())
}

fn configure_session(app: &AppHandle, session_id: &str) -> Result<(), String> {
    let session_name = tmux_session_name(session_id);

    set_tmux_option(app, &session_name, "status", "off")?;
    set_tmux_option(app, &session_name, "mouse", "off")?;
    set_tmux_option(app, &session_name, "window-size", "latest")?;
    set_tmux_option(app, &session_name, "history-limit", "10000")
}

fn set_tmux_option(app: &AppHandle, target: &str, option: &str, value: &str) -> Result<(), String> {
    let status = tmux_command(app)?
        .args(["set-option", "-t", target, option, value])
        .status()
        .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

    if status.success() {
        return Ok(());
    }

    Err(format!("failed to set tmux option {option}"))
}

fn send_tmux_copy_mode_command(
    app: &AppHandle,
    target: &str,
    count: &str,
    command: &str,
    quiet: bool,
) -> Result<(), String> {
    let mut tmux = tmux_command(app)?;

    tmux.args(["send-keys", "-t", target, "-N", count, "-X", command]);

    if quiet {
        tmux.stderr(Stdio::null());
    }

    let status = tmux
        .status()
        .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

    if status.success() {
        return Ok(());
    }

    Err(format!("failed to scroll terminal {command}"))
}

fn has_session(app: &AppHandle, session_id: &str) -> Result<bool, String> {
    let status = tmux_command(app)?
        .args(["has-session", "-t", &tmux_session_name(session_id)])
        .status()
        .map_err(|error| format!("failed to run bundled tmux: {error}"))?;

    Ok(status.success())
}

fn is_idle_terminal_command(command: &str) -> bool {
    let name = command_name(command);

    if is_tty_command(&name) {
        return true;
    }

    is_shell_command(&name)
}

fn is_shell_command(command: &str) -> bool {
    let configured_shell = env::var_os("SHELL")
        .and_then(|shell| shell.into_string().ok())
        .map(|shell| command_name(&shell));

    if configured_shell.as_deref() == Some(command) {
        return true;
    }

    if shell_names_from_etc().contains(command) {
        return true;
    }

    matches!(
        command,
        "bash" | "dash" | "fish" | "ksh" | "nu" | "sh" | "zsh"
    )
}

fn shell_names_from_etc() -> HashSet<String> {
    fs::read_to_string("/etc/shells")
        .ok()
        .map(|shells| {
            shells
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty() && !line.starts_with('#'))
                .map(command_name)
                .collect()
        })
        .unwrap_or_default()
}

fn tmux_command(app: &AppHandle) -> Result<Command, String> {
    let mut command = Command::new(tmux_binary_path(app)?);

    command.arg("-f");
    command.arg("/dev/null");
    command.arg("-S");
    command.arg(tmux_socket_path(app)?);

    Ok(command)
}

fn tmux_binary_path(app: &AppHandle) -> Result<PathBuf, String> {
    let binary_name = tmux_binary_name();
    let debug_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("resources/tmux/bin")
        .join(binary_name);

    if debug_path.exists() {
        return Ok(debug_path);
    }

    let mut candidates = Vec::new();

    if let Ok(resource_dir) = app.path().resource_dir() {
        candidates.push(resource_dir.join("tmux/bin").join(binary_name));
        candidates.push(resource_dir.join(binary_name));
        candidates.push(resource_dir.join("tmux"));
    }

    if let Ok(current_exe) = env::current_exe() {
        if let Some(exe_dir) = current_exe.parent() {
            candidates.push(exe_dir.join(binary_name));
            candidates.push(exe_dir.join("tmux"));
        }
    }

    candidates
        .into_iter()
        .find(|path| path.exists())
        .ok_or_else(|| "bundled tmux is missing".into())
}

fn tmux_binary_name() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "tmux-aarch64-apple-darwin"
    }

    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        "tmux"
    }
}

fn tmux_socket_path(app: &AppHandle) -> Result<PathBuf, String> {
    let socket_dir = app
        .path()
        .app_data_dir()
        .map_err(|error| error.to_string())?
        .join("tmux");

    fs::create_dir_all(&socket_dir).map_err(|error| error.to_string())?;

    Ok(socket_dir.join("pinata.sock"))
}

fn tmux_session_name(session_id: &str) -> String {
    let suffix: String = session_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '_'
            }
        })
        .collect();

    format!("{TMUX_SESSION_PREFIX}_{suffix}")
}

fn detach_attachment(state: &State<TerminalState>, session_id: &str) {
    let attachment = state
        .attachments
        .lock()
        .ok()
        .and_then(|mut attachments| attachments.remove(session_id));

    if let Some(mut attachment) = attachment {
        let _ = attachment.child.kill();
        let _ = attachment.child.wait();
    }
}

fn default_shell() -> PathBuf {
    env::var_os("SHELL")
        .map(PathBuf::from)
        .filter(|path| path.exists())
        .unwrap_or_else(|| PathBuf::from("/bin/zsh"))
}

fn login_shell_command(shell: &Path) -> String {
    let Some(shell) = shell.to_str() else {
        return "/bin/zsh -l".into();
    };

    match shell.rsplit('/').next() {
        Some("bash" | "fish" | "zsh") => format!("{shell} -l"),
        _ => shell.into(),
    }
}

fn expand_home(path: &str) -> Result<PathBuf, String> {
    if path == "~" {
        return env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| "HOME is not set".to_string());
    }

    if let Some(rest) = path.strip_prefix("~/") {
        let home = env::var_os("HOME").ok_or_else(|| "HOME is not set".to_string())?;
        return Ok(PathBuf::from(home).join(rest));
    }

    Ok(PathBuf::from(path))
}

#[cfg(test)]
mod tests {
    use super::{
        command_label, foreground_command_from_ps_output, is_idle_terminal_command,
        login_shell_command, parse_ps_process, tmux_session_name,
    };
    use std::path::Path;

    #[test]
    fn session_name_is_stable_and_tmux_safe() {
        assert_eq!(
            tmux_session_name("terminal-session-abc-123"),
            "pinata_terminal_session_abc_123"
        );
    }

    #[test]
    fn zsh_runs_as_login_shell() {
        assert_eq!(login_shell_command(Path::new("/bin/zsh")), "/bin/zsh -l");
    }

    #[test]
    fn foreground_shells_are_idle() {
        assert!(is_idle_terminal_command("/bin/zsh"));
        assert!(is_idle_terminal_command("ttys004"));
        assert!(!is_idle_terminal_command("node"));
    }

    #[test]
    fn shim_command_uses_invoked_command_label() {
        assert_eq!(
            command_label("/Users/me/.volta/bin/volta-shim", "volta-shim pi"),
            Some("pi".into())
        );
    }

    #[test]
    fn tty_label_uses_invoked_command_label() {
        assert_eq!(command_label("ttys000", "pi"), Some("pi".into()));
        assert_eq!(command_label("/dev/ttys000", "/dev/ttys000"), None);
    }

    #[test]
    fn foreground_process_uses_leaf_process_label() {
        let output = "\
89065 89064 S+   zsh      /bin/zsh -l
89335 89065 S+   pi       pi
89336 89335 S+   pi       pi
";

        assert_eq!(foreground_command_from_ps_output(output), Some("pi".into()));
    }

    #[test]
    fn parses_foreground_process_rows() {
        let process = parse_ps_process("84146 84002 S+   pi       pi").expect("row parses");

        assert_eq!(process.stat, "S+");
        assert_eq!(process.comm, "pi");
        assert_eq!(process.command, "pi");
    }
}
