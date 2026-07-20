use base64::{engine::general_purpose::STANDARD, Engine as _};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
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

#[tauri::command]
pub fn terminal_ensure_session(app: AppHandle, input: TerminalSessionInput) -> Result<(), String> {
    ensure_session(&app, &input.session_id, &input.cwd)
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
    use super::{login_shell_command, tmux_session_name};
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
}
