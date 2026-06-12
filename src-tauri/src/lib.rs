use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    env, fs,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Emitter, Manager};

const PINATA_EVENT: &str = "pinata-event";

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct PinataState {
    active_workspace_id: Option<String>,
    workspaces: Vec<Workspace>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Workspace {
    id: String,
    name: String,
    path: String,
    active_session_file: Option<String>,
    created_at: String,
    last_opened_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct PinataConfig {
    pi_executable_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConnectionSnapshot {
    status: String,
    message: Option<String>,
    error: Option<ConnectionError>,
    pi_executable_path: Option<String>,
    workspace_id: Option<String>,
    session_id: Option<String>,
    session_name: Option<String>,
    session_file: Option<String>,
    model: Option<ModelSummary>,
    thinking_level: Option<String>,
    tool_activity: Option<String>,
}

impl Default for ConnectionSnapshot {
    fn default() -> Self {
        Self {
            status: "booting".to_string(),
            message: Some("Starting Piñata…".to_string()),
            error: None,
            pi_executable_path: None,
            workspace_id: None,
            session_id: None,
            session_name: None,
            session_file: None,
            model: None,
            thinking_level: None,
            tool_activity: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConnectionError {
    code: String,
    title: String,
    message: String,
    details: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelSummary {
    provider: Option<String>,
    id: Option<String>,
    name: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TimelineItem {
    id: String,
    role: String,
    text: String,
    status: String,
    created_at: String,
    tool_name: Option<String>,
    detail: Option<String>,
}

#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum PinataEvent {
    AppState { state: PinataState },
    Connection { connection: ConnectionSnapshot },
    TimelineReset { items: Vec<TimelineItem> },
    TimelineItemAdded { item: TimelineItem },
    TimelineItemUpdated { item: TimelineItem },
    TimelineItemDelta { id: String, delta: String },
    TimelineItemStatus { id: String, status: String },
    ExtensionUiRequest { request: Box<Value> },
    Notice { message: String },
}

struct PiProcess {
    process_id: String,
    stdin: Arc<Mutex<ChildStdin>>,
    child: Arc<Mutex<Child>>,
}

#[derive(Default)]
struct RuntimeInner {
    state: PinataState,
    config: PinataConfig,
    connection: ConnectionSnapshot,
    pi: Option<PiProcess>,
    current_assistant_item_id: Option<String>,
    active_tool_items: HashMap<String, TimelineItem>,
    stderr_tail: String,
}

struct PinataRuntime {
    inner: Mutex<RuntimeInner>,
    pending_requests: Mutex<HashMap<String, mpsc::Sender<Value>>>,
    request_counter: AtomicU64,
    event_counter: AtomicU64,
}

impl Default for PinataRuntime {
    fn default() -> Self {
        Self {
            inner: Mutex::new(RuntimeInner::default()),
            pending_requests: Mutex::new(HashMap::new()),
            request_counter: AtomicU64::new(1),
            event_counter: AtomicU64::new(1),
        }
    }
}

impl PinataRuntime {
    fn next_rpc_id(&self) -> String {
        let value = self.request_counter.fetch_add(1, Ordering::Relaxed);
        format!("rpc-{value}")
    }

    fn next_ui_id(&self, prefix: &str) -> String {
        let value = self.event_counter.fetch_add(1, Ordering::Relaxed);
        format!("{prefix}-{}-{value}", now_millis())
    }
}

#[tauri::command]
fn bootstrap_app(app: AppHandle) -> Result<(), String> {
    let state = match load_state_file() {
        Ok(state) => state,
        Err(error) => {
            set_connection_error(
                &app,
                "stateReadFailed",
                "Could not read Piñata state",
                "Piñata could not read ~/.pinata/state.json.",
                Some(error.clone()),
            );
            return Err(error);
        }
    };

    let config = match load_config_file() {
        Ok(config) => config,
        Err(error) => {
            set_connection_error(
                &app,
                "stateReadFailed",
                "Could not read Piñata config",
                "Piñata could not read ~/.pinata/config.json.",
                Some(error.clone()),
            );
            return Err(error);
        }
    };

    {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = runtime.inner.lock().map_err(lock_error)?;
        inner.state = state.clone();
        inner.config = config;
        inner.connection = ConnectionSnapshot::default();
    }

    emit_event(&app, PinataEvent::AppState { state: state.clone() });

    if let Some(workspace_id) = state.active_workspace_id.clone() {
        start_workspace_connection(app, workspace_id);
    } else {
        set_connection_status(
            &app,
            "noWorkspace",
            Some("Open a workspace to start Pi.".to_string()),
        );
        emit_event(&app, PinataEvent::TimelineReset { items: Vec::new() });
    }

    Ok(())
}

#[tauri::command]
async fn open_workspace(app: AppHandle) -> Result<(), String> {
    ensure_not_streaming(&app)?;

    let selected_path = tauri::async_runtime::spawn_blocking(choose_workspace_folder)
        .await
        .map_err(|error| format!("Could not open workspace picker: {error}"))??;

    let Some(path) = selected_path else {
        return Ok(());
    };

    let path = canonical_workspace_path(&path)?;
    let path_string = path_to_string(&path);
    let now = now_string();
    let workspace_id = {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = runtime.inner.lock().map_err(lock_error)?;

        let workspace_id = if let Some(workspace) = inner
            .state
            .workspaces
            .iter_mut()
            .find(|workspace| workspace.path == path_string)
        {
            workspace.last_opened_at = now.clone();
            workspace.id.clone()
        } else {
            let id = runtime.next_ui_id("workspace");
            inner.state.workspaces.push(Workspace {
                id: id.clone(),
                name: workspace_name(&path),
                path: path_string,
                active_session_file: None,
                created_at: now.clone(),
                last_opened_at: now,
            });
            id
        };

        inner.state.active_workspace_id = Some(workspace_id.clone());
        save_state_file(&inner.state)?;
        workspace_id
    };

    emit_app_state(&app)?;
    start_workspace_connection(app, workspace_id);

    Ok(())
}

#[tauri::command]
fn activate_workspace(app: AppHandle, workspace_id: String) -> Result<(), String> {
    ensure_not_streaming(&app)?;

    let should_connect = {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = runtime.inner.lock().map_err(lock_error)?;

        if !inner
            .state
            .workspaces
            .iter()
            .any(|workspace| workspace.id == workspace_id)
        {
            return Err("Workspace not found.".to_string());
        }

        if let Some(workspace) = inner
            .state
            .workspaces
            .iter_mut()
            .find(|workspace| workspace.id == workspace_id)
        {
            workspace.last_opened_at = now_string();
        }

        let changed = inner.state.active_workspace_id.as_deref() != Some(workspace_id.as_str());
        inner.state.active_workspace_id = Some(workspace_id.clone());
        save_state_file(&inner.state)?;
        changed || inner.pi.is_none()
    };

    emit_app_state(&app)?;

    if should_connect {
        start_workspace_connection(app, workspace_id);
    }

    Ok(())
}

#[tauri::command]
fn send_prompt(app: AppHandle, message: String) -> Result<(), String> {
    let message = message.trim().to_string();
    if message.is_empty() {
        return Ok(());
    }

    ensure_not_streaming(&app)?;

    let item = {
        let runtime = app.state::<PinataRuntime>();
        TimelineItem {
            id: runtime.next_ui_id("user"),
            role: "user".to_string(),
            text: message.clone(),
            status: "done".to_string(),
            created_at: now_string(),
            tool_name: None,
            detail: None,
        }
    };
    emit_event(&app, PinataEvent::TimelineItemAdded { item });
    set_connection_status(&app, "streaming", Some("Pi is responding…".to_string()));

    let response = match send_rpc_command(
        &app,
        json!({
            "type": "prompt",
            "message": message,
        }),
        Duration::from_secs(30),
    ) {
        Ok(response) => response,
        Err(error) => {
            set_connection_error(
                &app,
                "rpcCommandFailed",
                "Could not send prompt",
                "Piñata could not send the prompt to Pi.",
                Some(error.clone()),
            );
            return Err(error);
        }
    };

    if !response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let error = response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Pi rejected the prompt.")
            .to_string();
        set_connection_error(
            &app,
            "rpcCommandFailed",
            "Pi rejected the prompt",
            "Pi did not accept the prompt.",
            Some(error.clone()),
        );
        return Err(error);
    }

    Ok(())
}

#[tauri::command]
fn abort_prompt(app: AppHandle) -> Result<(), String> {
    let response = send_rpc_command(
        &app,
        json!({
            "type": "abort",
        }),
        Duration::from_secs(10),
    )?;

    if response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        Ok(())
    } else {
        Err(response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Pi could not abort the current operation.")
            .to_string())
    }
}

#[tauri::command]
fn respond_extension_ui(app: AppHandle, response: Value) -> Result<(), String> {
    let mut response = response;
    if let Some(object) = response.as_object_mut() {
        object
            .entry("type".to_string())
            .or_insert_with(|| Value::String("extension_ui_response".to_string()));
    }

    write_rpc_message(&app, &response)
}

fn start_workspace_connection(app: AppHandle, workspace_id: String) {
    thread::spawn(move || connect_workspace(app, workspace_id));
}

fn connect_workspace(app: AppHandle, workspace_id: String) {
    let workspace = match workspace_by_id(&app, &workspace_id) {
        Ok(Some(workspace)) => workspace,
        Ok(None) => {
            set_connection_status(
                &app,
                "noWorkspace",
                Some("Open a workspace to start Pi.".to_string()),
            );
            return;
        }
        Err(error) => {
            set_connection_error(
                &app,
                "stateReadFailed",
                "Could not load workspace",
                "Piñata could not load the selected workspace.",
                Some(error),
            );
            return;
        }
    };

    let workspace_path = PathBuf::from(&workspace.path);
    if !workspace_path.is_dir() {
        set_connection_error(
            &app,
            "workspaceMissing",
            "Workspace path not found",
            "Piñata could not find the selected workspace path.",
            Some(workspace.path.clone()),
        );
        emit_event(&app, PinataEvent::TimelineReset { items: Vec::new() });
        return;
    }

    if let Some(session_file) = &workspace.active_session_file {
        if !Path::new(session_file).is_file() {
            set_connection_error(
                &app,
                "sessionMissing",
                "Saved Pi session not found",
                "Piñata found the workspace, but the Pi session file it was using no longer exists.",
                Some(session_file.clone()),
            );
            emit_event(&app, PinataEvent::TimelineReset { items: Vec::new() });
            return;
        }
    }

    set_connection_status(
        &app,
        "locatingPi",
        Some("Looking for Pi…".to_string()),
    );

    let config = match runtime_config(&app) {
        Ok(config) => config,
        Err(error) => {
            set_connection_error(
                &app,
                "stateReadFailed",
                "Could not read Piñata config",
                "Piñata could not read ~/.pinata/config.json.",
                Some(error),
            );
            return;
        }
    };

    let pi_path = match resolve_pi_executable(&config) {
        Ok(path) => path,
        Err(error) => {
            set_connection_error(
                &app,
                "piNotFound",
                "Pi executable not found",
                "Install Pi or set piExecutablePath in ~/.pinata/config.json.",
                Some(error),
            );
            return;
        }
    };

    if let Err(error) = stop_current_pi(&app) {
        set_connection_error(
            &app,
            "piSpawnFailed",
            "Could not stop previous Pi process",
            "Piñata could not stop the previous Pi process before switching workspaces.",
            Some(error),
        );
        return;
    }

    set_connection_status(
        &app,
        "startingPi",
        Some("Starting Pi…".to_string()),
    );
    update_connection(&app, |connection| {
        connection.workspace_id = Some(workspace.id.clone());
        connection.pi_executable_path = Some(path_to_string(&pi_path));
    });

    let process_id = {
        let runtime = app.state::<PinataRuntime>();
        runtime.next_ui_id("pi")
    };

    let mut command = Command::new(&pi_path);
    command
        .arg("--mode")
        .arg("rpc")
        .current_dir(&workspace.path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("PATH", child_path_env());

    if let Some(session_file) = &workspace.active_session_file {
        command.arg("--session").arg(session_file);
    } else {
        command.arg("--name").arg(format!("Piñata: {}", workspace.name));
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            set_connection_error(
                &app,
                "piSpawnFailed",
                "Could not start Pi",
                "Piñata found Pi but could not start it for this workspace.",
                Some(error.to_string()),
            );
            return;
        }
    };

    let Some(stdin) = child.stdin.take() else {
        set_connection_error(
            &app,
            "piSpawnFailed",
            "Could not open Pi stdin",
            "Piñata started Pi but could not open its input stream.",
            None,
        );
        return;
    };

    let Some(stdout) = child.stdout.take() else {
        set_connection_error(
            &app,
            "piSpawnFailed",
            "Could not open Pi stdout",
            "Piñata started Pi but could not open its output stream.",
            None,
        );
        return;
    };

    let stderr = child.stderr.take();
    let child = Arc::new(Mutex::new(child));
    let stdin = Arc::new(Mutex::new(stdin));

    {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = match runtime.inner.lock() {
            Ok(inner) => inner,
            Err(error) => {
                set_connection_error(
                    &app,
                    "piSpawnFailed",
                    "Could not store Pi process",
                    "Piñata started Pi but could not store the process handle.",
                    Some(error.to_string()),
                );
                return;
            }
        };
        inner.stderr_tail.clear();
        inner.current_assistant_item_id = None;
        inner.active_tool_items.clear();
        inner.pi = Some(PiProcess {
            process_id: process_id.clone(),
            stdin: stdin.clone(),
            child: child.clone(),
        });
    }

    spawn_stdout_reader(app.clone(), process_id.clone(), stdout);
    if let Some(stderr) = stderr {
        spawn_stderr_reader(app.clone(), process_id.clone(), stderr);
    }
    spawn_process_monitor(app.clone(), process_id.clone(), child);

    set_connection_status(
        &app,
        "restoringSession",
        Some("Restoring Pi session…".to_string()),
    );

    let state_response = match send_rpc_command(
        &app,
        json!({ "type": "get_state" }),
        Duration::from_secs(30),
    ) {
        Ok(response) => response,
        Err(error) => {
            set_connection_error(
                &app,
                "rpcCommandFailed",
                "Pi did not answer get_state",
                "Piñata started Pi but could not read its session state.",
                Some(error),
            );
            return;
        }
    };

    if !state_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let error = state_response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("get_state failed")
            .to_string();
        set_connection_error(
            &app,
            "rpcCommandFailed",
            "Pi rejected get_state",
            "Piñata started Pi but Pi rejected the state request.",
            Some(error),
        );
        return;
    }

    let state_data = state_response.get("data").cloned().unwrap_or(Value::Null);
    let session_file = state_data
        .get("sessionFile")
        .and_then(Value::as_str)
        .map(str::to_string);
    let session_id = state_data
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_string);
    let session_name = state_data
        .get("sessionName")
        .and_then(Value::as_str)
        .map(str::to_string);
    let model = state_data.get("model").and_then(model_summary);
    let thinking_level = state_data
        .get("thinkingLevel")
        .and_then(Value::as_str)
        .or_else(|| state_data.get("thinking_level").and_then(Value::as_str))
        .map(str::to_string);

    if let Some(session_file) = &session_file {
        if let Err(error) = update_workspace_session_file(&app, &workspace.id, session_file) {
            set_connection_error(
                &app,
                "stateReadFailed",
                "Could not save Pi session",
                "Piñata connected to Pi but could not persist the session file.",
                Some(error),
            );
            return;
        }
    }

    update_connection(&app, |connection| {
        connection.status = "hydratingTimeline".to_string();
        connection.message = Some("Loading previous messages…".to_string());
        connection.error = None;
        connection.session_file = session_file.clone();
        connection.session_id = session_id;
        connection.session_name = session_name;
        connection.model = model;
        connection.thinking_level = thinking_level;
        connection.tool_activity = None;
    });

    let messages_response = match send_rpc_command(
        &app,
        json!({ "type": "get_messages" }),
        Duration::from_secs(30),
    ) {
        Ok(response) => response,
        Err(error) => {
            set_connection_error(
                &app,
                "rpcCommandFailed",
                "Pi did not answer get_messages",
                "Piñata restored the Pi session but could not load its messages.",
                Some(error),
            );
            return;
        }
    };

    if !messages_response
        .get("success")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let error = messages_response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("get_messages failed")
            .to_string();
        set_connection_error(
            &app,
            "rpcCommandFailed",
            "Pi rejected get_messages",
            "Piñata restored the Pi session but Pi rejected the message request.",
            Some(error),
        );
        return;
    }

    let messages = messages_response
        .get("data")
        .and_then(|data| data.get("messages"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let items = hydrate_timeline(&app, &messages);
    emit_event(&app, PinataEvent::TimelineReset { items });
    set_connection_status(&app, "ready", Some("Pi is ready.".to_string()));
}

fn spawn_stdout_reader(app: AppHandle, process_id: String, stdout: impl std::io::Read + Send + 'static) {
    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            match line {
                Ok(line) => handle_pi_stdout_line(&app, &process_id, &line),
                Err(error) => {
                    if is_current_process(&app, &process_id) {
                        set_connection_error(
                            &app,
                            "rpcProtocolError",
                            "Could not read Pi output",
                            "Piñata lost the Pi output stream.",
                            Some(error.to_string()),
                        );
                    }
                    break;
                }
            }
        }
    });
}

fn spawn_stderr_reader(app: AppHandle, process_id: String, stderr: impl std::io::Read + Send + 'static) {
    thread::spawn(move || {
        let reader = BufReader::new(stderr);
        for line in reader.lines().map_while(Result::ok) {
            append_stderr_tail(&app, &process_id, &line);
        }
    });
}

fn spawn_process_monitor(app: AppHandle, process_id: String, child: Arc<Mutex<Child>>) {
    thread::spawn(move || loop {
        thread::sleep(Duration::from_millis(500));

        let status = {
            let mut child = match child.lock() {
                Ok(child) => child,
                Err(_) => return,
            };
            match child.try_wait() {
                Ok(status) => status,
                Err(error) => {
                    if is_current_process(&app, &process_id) {
                        set_connection_error(
                            &app,
                            "piExited",
                            "Could not monitor Pi",
                            "Piñata could not monitor the Pi process.",
                            Some(error.to_string()),
                        );
                    }
                    return;
                }
            }
        };

        if let Some(status) = status {
            if is_current_process(&app, &process_id) {
                let stderr_tail = take_stderr_tail(&app, &process_id);
                {
                    let runtime = app.state::<PinataRuntime>();
                    if let Ok(mut inner) = runtime.inner.lock() {
                        inner.pi = None;
                        inner.current_assistant_item_id = None;
                        inner.active_tool_items.clear();
                    };
                }

                set_connection_error(
                    &app,
                    "piExited",
                    "Pi exited",
                    "The Pi RPC process exited.",
                    Some(format!("status: {status}\n{stderr_tail}")),
                );
            }
            return;
        }
    });
}

fn handle_pi_stdout_line(app: &AppHandle, process_id: &str, line: &str) {
    let line = line.trim_end_matches('\r');
    if line.trim().is_empty() {
        return;
    }

    let value: Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(error) => {
            if is_current_process(app, process_id) {
                set_connection_error(
                    app,
                    "rpcProtocolError",
                    "Pi sent invalid JSON",
                    "Piñata received output from Pi that was not valid JSON-RPC.",
                    Some(format!("{error}\n{line}")),
                );
            }
            return;
        }
    };

    if value.get("type").and_then(Value::as_str) == Some("response") {
        if let Some(id) = value.get("id").and_then(Value::as_str) {
            let sender = {
                let runtime = app.state::<PinataRuntime>();
                runtime
                    .pending_requests
                    .lock()
                    .ok()
                    .and_then(|mut pending| pending.remove(id))
            };
            if let Some(sender) = sender {
                let _ = sender.send(value);
            }
        }
        return;
    }

    if !is_current_process(app, process_id) {
        return;
    }

    match value.get("type").and_then(Value::as_str) {
        Some("agent_start") => {
            set_connection_status(app, "streaming", Some("Pi is responding…".to_string()));
        }
        Some("agent_end") => {
            finish_current_assistant(app, "done");
            set_connection_status(app, "ready", Some("Pi is ready.".to_string()));
        }
        Some("message_update") => handle_message_update(app, &value),
        Some("message_end") => {
            if value
                .get("message")
                .and_then(|message| message.get("role"))
                .and_then(Value::as_str)
                == Some("assistant")
            {
                finish_current_assistant(app, "done");

                let stop_reason = value
                    .get("message")
                    .and_then(|message| message.get("stopReason"))
                    .and_then(Value::as_str);
                if stop_reason != Some("toolUse") {
                    set_connection_status(app, "ready", Some("Pi is ready.".to_string()));
                }
            }
        }
        Some("tool_execution_start") => handle_tool_execution_start(app, &value),
        Some("tool_execution_update") => handle_tool_execution_update(app, &value),
        Some("tool_execution_end") => handle_tool_execution_end(app, &value),
        Some("thinking_level_change") | Some("thinking_level_select") => handle_thinking_level_change(app, &value),
        Some("compaction_start") => add_activity_item(app, "Compacting context…", "streaming"),
        Some("compaction_end") => add_activity_item(app, "Context compacted", "done"),
        Some("auto_retry_start") => add_activity_item(app, "Pi is retrying after a transient error…", "streaming"),
        Some("auto_retry_end") => add_activity_item(app, "Retry finished", "done"),
        Some("extension_error") => add_activity_item(app, "Extension error", "error"),
        Some("extension_ui_request") => handle_extension_ui_request(app, value),
        Some("queue_update") | Some("turn_start") | Some("turn_end") | Some("message_start") => {}
        _ => {}
    }
}

fn handle_thinking_level_change(app: &AppHandle, value: &Value) {
    let level = value
        .get("thinkingLevel")
        .and_then(Value::as_str)
        .or_else(|| value.get("level").and_then(Value::as_str))
        .map(str::to_string);

    if let Some(level) = level {
        update_connection(app, |connection| {
            connection.thinking_level = Some(level);
        });
    }
}

fn handle_message_update(app: &AppHandle, value: &Value) {
    let Some(delta) = value.get("assistantMessageEvent") else {
        return;
    };

    match delta.get("type").and_then(Value::as_str) {
        Some("text_delta") => {
            if let Some(text_delta) = delta.get("delta").and_then(Value::as_str) {
                append_assistant_delta(app, text_delta);
            }
        }
        Some("toolcall_start") => {}
        Some("error") => {
            finish_current_assistant(app, "error");
            let details = delta
                .get("reason")
                .and_then(Value::as_str)
                .or_else(|| delta.get("error").and_then(Value::as_str))
                .unwrap_or("Assistant message failed.")
                .to_string();
            set_connection_error(
                app,
                "rpcCommandFailed",
                "Pi message failed",
                "Pi reported an error while generating a response.",
                Some(details),
            );
        }
        Some("done") => {
            finish_current_assistant(app, "done");
            if delta.get("reason").and_then(Value::as_str) != Some("toolUse") {
                set_connection_status(app, "ready", Some("Pi is ready.".to_string()));
            }
        }
        _ => {}
    }
}

fn handle_tool_execution_start(app: &AppHandle, value: &Value) {
    let tool_name = value
        .get("toolName")
        .and_then(Value::as_str)
        .unwrap_or("tool");
    let tool_call_id = value
        .get("toolCallId")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| {
            let runtime = app.state::<PinataRuntime>();
            runtime.next_ui_id("tool-call")
        });
    let title = tool_title(tool_name, value.get("args")).unwrap_or_else(|| format!("Running {tool_name}…"));

    let item = {
        let runtime = app.state::<PinataRuntime>();
        let item = TimelineItem {
            id: runtime.next_ui_id("activity"),
            role: "activity".to_string(),
            text: title.clone(),
            status: "streaming".to_string(),
            created_at: now_string(),
            tool_name: Some(tool_name.to_string()),
            detail: None,
        };

        if let Ok(mut inner) = runtime.inner.lock() {
            inner.active_tool_items.insert(tool_call_id, item.clone());
        }

        item
    };

    emit_event(app, PinataEvent::TimelineItemAdded { item });
    update_connection(app, |connection| {
        connection.tool_activity = Some(format!("Running {tool_name}…"));
    });
}

fn handle_tool_execution_update(app: &AppHandle, value: &Value) {
    let Some(tool_call_id) = value.get("toolCallId").and_then(Value::as_str) else {
        return;
    };
    let detail = value
        .get("partialResult")
        .and_then(tool_output_from_result)
        .or_else(|| value.get("result").and_then(tool_output_from_result));

    let Some(item) = detail.and_then(|detail| {
        let runtime = app.state::<PinataRuntime>();
        runtime.inner.lock().ok().and_then(|mut inner| {
            let item = inner.active_tool_items.get_mut(tool_call_id)?;
            item.detail = Some(detail);
            Some(item.clone())
        })
    }) else {
        return;
    };

    emit_event(app, PinataEvent::TimelineItemUpdated { item });
}

fn handle_tool_execution_end(app: &AppHandle, value: &Value) {
    let tool_name = value
        .get("toolName")
        .and_then(Value::as_str)
        .unwrap_or("tool");
    let tool_call_id = value.get("toolCallId").and_then(Value::as_str);
    let is_error = value
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let detail = value.get("result").and_then(tool_output_from_result);

    let (item, existed) = {
        let runtime = app.state::<PinataRuntime>();
        let existing = tool_call_id.and_then(|id| {
            runtime
                .inner
                .lock()
                .ok()
                .and_then(|mut inner| inner.active_tool_items.remove(id))
        });
        let existed = existing.is_some();

        let mut item = existing.unwrap_or_else(|| TimelineItem {
            id: runtime.next_ui_id("activity"),
            role: "activity".to_string(),
            text: tool_title(tool_name, value.get("args")).unwrap_or_else(|| format!("{tool_name} result")),
            status: "streaming".to_string(),
            created_at: now_string(),
            tool_name: Some(tool_name.to_string()),
            detail: None,
        });

        item.status = if is_error { "error" } else { "done" }.to_string();
        item.detail = detail;
        (item, existed)
    };

    if existed {
        emit_event(app, PinataEvent::TimelineItemUpdated { item });
    } else {
        emit_event(app, PinataEvent::TimelineItemAdded { item });
    }
    update_connection(app, |connection| {
        connection.tool_activity = None;
    });
}

fn tool_title(tool_name: &str, args: Option<&Value>) -> Option<String> {
    let args = args?;

    if tool_name == "mcp" && args.as_object().is_some_and(|object| object.is_empty()) {
        return Some("status".to_string());
    }

    let preferred_keys: &[&str] = match tool_name {
        "bash" => &["command"],
        "read" => &["path", "file", "filePath"],
        "write" | "edit" => &["path", "file", "filePath"],
        "mcp" => &["mode", "server", "tool", "name"],
        _ => &["command", "path", "file", "filePath", "name", "query"],
    };

    for key in preferred_keys {
        if let Some(value) = args.get(key).and_then(Value::as_str) {
            if !value.trim().is_empty() {
                return Some(value.trim().to_string());
            }
        }
    }

    if args.as_object().is_some_and(|object| object.is_empty()) {
        return None;
    }

    serde_json::to_string(args).ok()
}

fn tool_output_from_result(result: &Value) -> Option<String> {
    match result {
        Value::String(text) => non_empty_text(text),
        Value::Array(_) => non_empty_text(&text_from_content(Some(result)))
            .or_else(|| serde_json::to_string_pretty(result).ok()),
        Value::Object(object) => object
            .get("content")
            .and_then(|content| non_empty_text(&text_from_content(Some(content))))
            .or_else(|| object.get("output").and_then(Value::as_str).and_then(non_empty_text))
            .or_else(|| object.get("stdout").and_then(Value::as_str).and_then(non_empty_text))
            .or_else(|| object.get("stderr").and_then(Value::as_str).and_then(non_empty_text))
            .or_else(|| object.get("result").and_then(tool_output_from_result))
            .or_else(|| serde_json::to_string_pretty(result).ok()),
        Value::Null => None,
        _ => serde_json::to_string_pretty(result).ok(),
    }
}

fn non_empty_text(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

fn handle_extension_ui_request(app: &AppHandle, request: Value) {
    if request.get("method").and_then(Value::as_str) == Some("notify") {
        if let Some(message) = request.get("message").and_then(Value::as_str) {
            emit_event(
                app,
                PinataEvent::Notice {
                    message: message.to_string(),
                },
            );
        }
    }

    emit_event(
        app,
        PinataEvent::ExtensionUiRequest {
            request: Box::new(request),
        },
    );
}

fn append_assistant_delta(app: &AppHandle, delta: &str) {
    let maybe_item = {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = match runtime.inner.lock() {
            Ok(inner) => inner,
            Err(_) => return,
        };

        if inner.current_assistant_item_id.is_some() {
            None
        } else {
            let id = runtime.next_ui_id("assistant");
            inner.current_assistant_item_id = Some(id.clone());
            Some(TimelineItem {
                id,
                role: "assistant".to_string(),
                text: String::new(),
                status: "streaming".to_string(),
                created_at: now_string(),
                tool_name: None,
                detail: None,
            })
        }
    };

    if let Some(item) = maybe_item {
        emit_event(app, PinataEvent::TimelineItemAdded { item });
    }

    let id = {
        let runtime = app.state::<PinataRuntime>();
        runtime
            .inner
            .lock()
            .ok()
            .and_then(|inner| inner.current_assistant_item_id.clone())
    };

    if let Some(id) = id {
        emit_event(
            app,
            PinataEvent::TimelineItemDelta {
                id,
                delta: delta.to_string(),
            },
        );
    }
}

fn finish_current_assistant(app: &AppHandle, status: &str) {
    let id = {
        let runtime = app.state::<PinataRuntime>();
        runtime
            .inner
            .lock()
            .ok()
            .and_then(|mut inner| inner.current_assistant_item_id.take())
    };

    if let Some(id) = id {
        emit_event(
            app,
            PinataEvent::TimelineItemStatus {
                id,
                status: status.to_string(),
            },
        );
    }
}

fn add_activity_item(app: &AppHandle, text: &str, status: &str) {
    let item = {
        let runtime = app.state::<PinataRuntime>();
        TimelineItem {
            id: runtime.next_ui_id("activity"),
            role: "activity".to_string(),
            text: text.to_string(),
            status: status.to_string(),
            created_at: now_string(),
            tool_name: None,
            detail: None,
        }
    };
    emit_event(app, PinataEvent::TimelineItemAdded { item });
}

fn hydrate_timeline(app: &AppHandle, messages: &[Value]) -> Vec<TimelineItem> {
    let runtime = app.state::<PinataRuntime>();
    let mut items = Vec::new();
    let mut pending_tool_calls: HashMap<String, ToolCallSummary> = HashMap::new();

    for message in messages {
        match message.get("role").and_then(Value::as_str) {
            Some("user") => {
                let text = text_from_content(message.get("content"));
                if !text.trim().is_empty() {
                    items.push(TimelineItem {
                        id: runtime.next_ui_id("history-user"),
                        role: "user".to_string(),
                        text,
                        status: "done".to_string(),
                        created_at: timestamp_from_message(message),
                        tool_name: None,
                        detail: None,
                    });
                }
            }
            Some("assistant") => {
                let text = assistant_text(message);
                if !text.trim().is_empty() {
                    items.push(TimelineItem {
                        id: runtime.next_ui_id("history-assistant"),
                        role: "assistant".to_string(),
                        text,
                        status: assistant_status(message),
                        created_at: timestamp_from_message(message),
                        tool_name: None,
                        detail: None,
                    });
                }

                for tool_call in assistant_tool_calls(message) {
                    pending_tool_calls.insert(tool_call.id.clone(), tool_call);
                }
            }
            Some("toolResult") => {
                let message_tool_name = message
                    .get("toolName")
                    .and_then(Value::as_str)
                    .unwrap_or("tool");
                let tool_call = message
                    .get("toolCallId")
                    .and_then(Value::as_str)
                    .and_then(|id| pending_tool_calls.remove(id));
                let (tool_name, title_from_call) = match tool_call {
                    Some(call) => (call.name, Some(call.title)),
                    None => (message_tool_name.to_string(), None),
                };
                let is_error = message
                    .get("isError")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let output = text_from_content(message.get("content"));
                let title = title_from_call
                    .filter(|title| !title.trim().is_empty())
                    .unwrap_or_else(|| tool_result_title(&tool_name, message, is_error));

                items.push(TimelineItem {
                    id: runtime.next_ui_id("history-activity"),
                    role: "activity".to_string(),
                    text: title,
                    status: if is_error { "error" } else { "done" }.to_string(),
                    created_at: timestamp_from_message(message),
                    tool_name: Some(tool_name),
                    detail: tool_result_detail(&output),
                });
            }
            Some("bashExecution") => {
                let command = message
                    .get("command")
                    .and_then(Value::as_str)
                    .unwrap_or("command");
                let output = bash_execution_output(message);
                items.push(TimelineItem {
                    id: runtime.next_ui_id("history-activity"),
                    role: "activity".to_string(),
                    text: command.to_string(),
                    status: if message
                        .get("exitCode")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        == 0
                    {
                        "done"
                    } else {
                        "error"
                    }
                    .to_string(),
                    created_at: timestamp_from_message(message),
                    tool_name: Some("bash".to_string()),
                    detail: output,
                });
            }
            _ => {}
        }
    }

    items
}

fn tool_result_title(tool_name: &str, message: &Value, is_error: bool) -> String {
    message
        .get("details")
        .and_then(|details| details.get("mode"))
        .and_then(Value::as_str)
        .or_else(|| {
            message
                .get("details")
                .and_then(|details| details.get("command"))
                .and_then(Value::as_str)
        })
        .or_else(|| {
            message
                .get("details")
                .and_then(|details| details.get("path"))
                .and_then(Value::as_str)
        })
        .map(str::to_string)
        .unwrap_or_else(|| {
            if is_error {
                "failed".to_string()
            } else {
                format!("{tool_name} result")
            }
        })
}

fn tool_result_detail(output: &str) -> Option<String> {
    let output = output.trim();
    if output.is_empty() {
        None
    } else {
        Some(output.to_string())
    }
}

fn bash_execution_output(message: &Value) -> Option<String> {
    let output = message
        .get("output")
        .and_then(Value::as_str)
        .or_else(|| message.get("stdout").and_then(Value::as_str))
        .or_else(|| message.get("stderr").and_then(Value::as_str));

    output
        .map(str::trim)
        .filter(|output| !output.is_empty())
        .map(str::to_string)
}

struct ToolCallSummary {
    id: String,
    name: String,
    title: String,
}

fn assistant_tool_calls(message: &Value) -> Vec<ToolCallSummary> {
    match message.get("content") {
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| {
                if block.get("type").and_then(Value::as_str) != Some("toolCall") {
                    return None;
                }

                let id = block.get("id").and_then(Value::as_str)?.to_string();
                let name = block
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("tool")
                    .to_string();
                let title = tool_title(&name, block.get("arguments"))
                    .or_else(|| tool_title(&name, block.get("args")))
                    .unwrap_or_else(|| format!("{name} result"));

                Some(ToolCallSummary { id, name, title })
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn text_from_content(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| match block.get("type").and_then(Value::as_str) {
                Some("text") => block.get("text").and_then(Value::as_str).map(str::to_string),
                Some("image") => Some("[Image attachment]".to_string()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
        _ => String::new(),
    }
}

fn assistant_text(message: &Value) -> String {
    match message.get("content") {
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| {
                if block.get("type").and_then(Value::as_str) == Some("text") {
                    block.get("text").and_then(Value::as_str).map(str::to_string)
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
        Some(Value::String(text)) => text.clone(),
        _ => String::new(),
    }
}

fn assistant_status(message: &Value) -> String {
    match message.get("stopReason").and_then(Value::as_str) {
        Some("error") | Some("aborted") => "error".to_string(),
        _ => "done".to_string(),
    }
}

fn timestamp_from_message(message: &Value) -> String {
    message
        .get("timestamp")
        .and_then(Value::as_i64)
        .map(|timestamp| timestamp.to_string())
        .unwrap_or_else(now_string)
}

fn send_rpc_command(app: &AppHandle, mut command: Value, timeout: Duration) -> Result<Value, String> {
    let runtime = app.state::<PinataRuntime>();
    let id = runtime.next_rpc_id();

    let Some(object) = command.as_object_mut() else {
        return Err("RPC command must be a JSON object.".to_string());
    };
    object.insert("id".to_string(), Value::String(id.clone()));

    let (sender, receiver) = mpsc::channel();
    {
        let mut pending = runtime.pending_requests.lock().map_err(lock_error)?;
        pending.insert(id.clone(), sender);
    }

    if let Err(error) = write_rpc_message(app, &command) {
        let mut pending = runtime.pending_requests.lock().map_err(lock_error)?;
        pending.remove(&id);
        return Err(error);
    }

    receiver
        .recv_timeout(timeout)
        .map_err(|_| format!("Timed out waiting for Pi response to {id}."))
}

fn write_rpc_message(app: &AppHandle, message: &Value) -> Result<(), String> {
    let runtime = app.state::<PinataRuntime>();
    let stdin = {
        let inner = runtime.inner.lock().map_err(lock_error)?;
        inner
            .pi
            .as_ref()
            .map(|process| process.stdin.clone())
            .ok_or_else(|| "Pi is not connected.".to_string())?
    };

    let line = serde_json::to_string(message).map_err(|error| error.to_string())?;
    let mut stdin = stdin.lock().map_err(lock_error)?;
    stdin
        .write_all(line.as_bytes())
        .and_then(|_| stdin.write_all(b"\n"))
        .and_then(|_| stdin.flush())
        .map_err(|error| error.to_string())
}

fn stop_current_pi(app: &AppHandle) -> Result<(), String> {
    let process = {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = runtime.inner.lock().map_err(lock_error)?;
        inner.current_assistant_item_id = None;
        inner.active_tool_items.clear();
        inner.pi.take()
    };

    if let Some(process) = process {
        if let Ok(mut child) = process.child.lock() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    Ok(())
}

fn ensure_not_streaming(app: &AppHandle) -> Result<(), String> {
    let runtime = app.state::<PinataRuntime>();
    let inner = runtime.inner.lock().map_err(lock_error)?;
    if inner.connection.status == "streaming" {
        Err("Pi is currently responding. Wait or abort before switching workspaces.".to_string())
    } else {
        Ok(())
    }
}

fn workspace_by_id(app: &AppHandle, workspace_id: &str) -> Result<Option<Workspace>, String> {
    let runtime = app.state::<PinataRuntime>();
    let inner = runtime.inner.lock().map_err(lock_error)?;
    Ok(inner
        .state
        .workspaces
        .iter()
        .find(|workspace| workspace.id == workspace_id)
        .cloned())
}

fn runtime_config(app: &AppHandle) -> Result<PinataConfig, String> {
    let runtime = app.state::<PinataRuntime>();
    let inner = runtime.inner.lock().map_err(lock_error)?;
    Ok(inner.config.clone())
}

fn update_workspace_session_file(
    app: &AppHandle,
    workspace_id: &str,
    session_file: &str,
) -> Result<(), String> {
    {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = runtime.inner.lock().map_err(lock_error)?;
        if let Some(workspace) = inner
            .state
            .workspaces
            .iter_mut()
            .find(|workspace| workspace.id == workspace_id)
        {
            workspace.active_session_file = Some(session_file.to_string());
            workspace.last_opened_at = now_string();
        }
        save_state_file(&inner.state)?;
    }

    emit_app_state(app)
}

fn emit_app_state(app: &AppHandle) -> Result<(), String> {
    let state = {
        let runtime = app.state::<PinataRuntime>();
        let inner = runtime.inner.lock().map_err(lock_error)?;
        inner.state.clone()
    };
    emit_event(app, PinataEvent::AppState { state });
    Ok(())
}

fn update_connection(app: &AppHandle, update: impl FnOnce(&mut ConnectionSnapshot)) {
    let connection = {
        let runtime = app.state::<PinataRuntime>();
        let mut inner = match runtime.inner.lock() {
            Ok(inner) => inner,
            Err(_) => return,
        };
        update(&mut inner.connection);
        inner.connection.clone()
    };

    emit_event(app, PinataEvent::Connection { connection });
}

fn set_connection_status(app: &AppHandle, status: &str, message: Option<String>) {
    update_connection(app, |connection| {
        connection.status = status.to_string();
        connection.message = message;
        if status != "error" {
            connection.error = None;
        }
    });
}

fn set_connection_error(
    app: &AppHandle,
    code: &str,
    title: &str,
    message: &str,
    details: Option<String>,
) {
    update_connection(app, |connection| {
        connection.status = "error".to_string();
        connection.message = Some(message.to_string());
        connection.error = Some(ConnectionError {
            code: code.to_string(),
            title: title.to_string(),
            message: message.to_string(),
            details,
        });
        connection.tool_activity = None;
    });
}

fn emit_event(app: &AppHandle, event: PinataEvent) {
    let _ = app.emit(PINATA_EVENT, event);
}

fn is_current_process(app: &AppHandle, process_id: &str) -> bool {
    let runtime = app.state::<PinataRuntime>();
    runtime
        .inner
        .lock()
        .ok()
        .and_then(|inner| {
            inner
                .pi
                .as_ref()
                .map(|process| process.process_id == process_id)
        })
        .unwrap_or(false)
}

fn append_stderr_tail(app: &AppHandle, process_id: &str, line: &str) {
    let runtime = app.state::<PinataRuntime>();
    if let Ok(mut inner) = runtime.inner.lock() {
        if inner
            .pi
            .as_ref()
            .map(|process| process.process_id.as_str() == process_id)
            .unwrap_or(false)
        {
            inner.stderr_tail.push_str(line);
            inner.stderr_tail.push('\n');
            if inner.stderr_tail.len() > 8_000 {
                let start = inner.stderr_tail.len().saturating_sub(8_000);
                inner.stderr_tail = inner.stderr_tail[start..].to_string();
            }
        }
    };
}

fn take_stderr_tail(app: &AppHandle, process_id: &str) -> String {
    let runtime = app.state::<PinataRuntime>();
    runtime
        .inner
        .lock()
        .ok()
        .and_then(|inner| {
            inner
                .pi
                .as_ref()
                .filter(|process| process.process_id == process_id)
                .map(|_| inner.stderr_tail.clone())
        })
        .unwrap_or_default()
}

fn load_state_file() -> Result<PinataState, String> {
    ensure_pinata_dir()?;
    let path = state_file_path()?;
    read_json_or_default(&path)
}

fn save_state_file(state: &PinataState) -> Result<(), String> {
    ensure_pinata_dir()?;
    let path = state_file_path()?;
    write_json_file(&path, state)
}

fn load_config_file() -> Result<PinataConfig, String> {
    ensure_pinata_dir()?;
    let path = config_file_path()?;
    if !path.exists() {
        let config = PinataConfig::default();
        write_json_file(&path, &config)?;
        return Ok(config);
    }
    read_json_or_default(&path)
}

fn read_json_or_default<T>(path: &Path) -> Result<T, String>
where
    T: DeserializeOwned + Default,
{
    if !path.exists() {
        return Ok(T::default());
    }

    let content = fs::read_to_string(path).map_err(|error| error.to_string())?;
    if content.trim().is_empty() {
        return Ok(T::default());
    }

    serde_json::from_str(&content).map_err(|error| error.to_string())
}

fn write_json_file<T>(path: &Path, value: &T) -> Result<(), String>
where
    T: Serialize,
{
    let content = serde_json::to_string_pretty(value).map_err(|error| error.to_string())?;
    let tmp_path = path.with_extension("json.tmp");
    fs::write(&tmp_path, content).map_err(|error| error.to_string())?;
    fs::rename(&tmp_path, path).map_err(|error| error.to_string())
}

fn ensure_pinata_dir() -> Result<(), String> {
    fs::create_dir_all(pinata_dir()?).map_err(|error| error.to_string())
}

fn state_file_path() -> Result<PathBuf, String> {
    Ok(pinata_dir()?.join("state.json"))
}

fn config_file_path() -> Result<PathBuf, String> {
    Ok(pinata_dir()?.join("config.json"))
}

fn pinata_dir() -> Result<PathBuf, String> {
    Ok(home_dir()?.join(".pinata"))
}

fn home_dir() -> Result<PathBuf, String> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| "HOME is not set.".to_string())
}

fn resolve_pi_executable(config: &PinataConfig) -> Result<PathBuf, String> {
    if let Some(path) = &config.pi_executable_path {
        let path = expand_home(path)?;
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "Configured piExecutablePath does not exist: {}",
            path_to_string(&path)
        ));
    }

    let home = home_dir()?;
    let mut candidates = vec![
        home.join(".volta/bin/pi"),
        PathBuf::from("/opt/homebrew/bin/pi"),
        PathBuf::from("/usr/local/bin/pi"),
        home.join(".npm-global/bin/pi"),
        home.join(".local/bin/pi"),
    ];

    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|path| path.join("pi")));
    }

    for candidate in candidates {
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    Err("Searched ~/.volta/bin/pi, /opt/homebrew/bin/pi, /usr/local/bin/pi, ~/.npm-global/bin/pi, ~/.local/bin/pi, and inherited PATH.".to_string())
}

fn expand_home(path: &str) -> Result<PathBuf, String> {
    if path == "~" {
        return home_dir();
    }

    if let Some(rest) = path.strip_prefix("~/") {
        return Ok(home_dir()?.join(rest));
    }

    Ok(PathBuf::from(path))
}

fn child_path_env() -> String {
    let mut paths = Vec::new();
    if let Ok(home) = home_dir() {
        paths.push(home.join(".volta/bin"));
        paths.push(home.join(".npm-global/bin"));
        paths.push(home.join(".local/bin"));
    }
    paths.push(PathBuf::from("/opt/homebrew/bin"));
    paths.push(PathBuf::from("/usr/local/bin"));
    paths.push(PathBuf::from("/usr/bin"));
    paths.push(PathBuf::from("/bin"));
    paths.push(PathBuf::from("/usr/sbin"));
    paths.push(PathBuf::from("/sbin"));

    if let Some(existing) = env::var_os("PATH") {
        paths.extend(env::split_paths(&existing));
    }

    env::join_paths(paths)
        .map(|paths| paths.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "/usr/bin:/bin:/usr/sbin:/sbin".to_string())
}

fn choose_workspace_folder() -> Result<Option<PathBuf>, String> {
    let output = Command::new("osascript")
        .arg("-e")
        .arg("POSIX path of (choose folder with prompt \"Open Piñata Workspace\")")
        .output()
        .map_err(|error| error.to_string())?;

    if output.status.success() {
        let path = String::from_utf8(output.stdout).map_err(|error| error.to_string())?;
        let path = path.trim();
        if path.is_empty() {
            Ok(None)
        } else {
            Ok(Some(PathBuf::from(path)))
        }
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("User canceled") || stderr.contains("-128") {
            Ok(None)
        } else {
            Err(stderr.trim().to_string())
        }
    }
}

fn canonical_workspace_path(path: &Path) -> Result<PathBuf, String> {
    let canonical = fs::canonicalize(path).map_err(|error| error.to_string())?;
    if canonical.is_dir() {
        Ok(canonical)
    } else {
        Err("Selected workspace is not a directory.".to_string())
    }
}

fn workspace_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.trim().is_empty())
        .unwrap_or("Workspace")
        .to_string()
}

fn model_summary(value: &Value) -> Option<ModelSummary> {
    if value.is_null() {
        return None;
    }

    Some(ModelSummary {
        provider: value
            .get("provider")
            .and_then(Value::as_str)
            .map(str::to_string),
        id: value.get("id").and_then(Value::as_str).map(str::to_string),
        name: value
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

fn now_string() -> String {
    now_millis().to_string()
}

fn lock_error<T>(error: std::sync::PoisonError<T>) -> String {
    error.to_string()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if let Err(error) = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(PinataRuntime::default())
        .invoke_handler(tauri::generate_handler![
            bootstrap_app,
            open_workspace,
            activate_workspace,
            send_prompt,
            abort_prompt,
            respond_extension_ui,
        ])
        .run(tauri::generate_context!())
    {
        eprintln!("error while running Tauri application: {error}");
    }
}
