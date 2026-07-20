use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs, path::PathBuf};
use tauri::{AppHandle, LogicalPosition, LogicalSize, Manager};

const APP_STATE_FILE: &str = "app-state.json";
const APP_STATE_VERSION: u8 = 1;
const DEFAULT_WORKTREE_BASE_PATH: &str = "~/.pinata/worktrees";
const MIN_WINDOW_WIDTH: u16 = 900;
const MIN_WINDOW_HEIGHT: u16 = 600;
const MAX_WINDOW_WIDTH: u16 = 4000;
const MAX_WINDOW_HEIGHT: u16 = 3000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppState {
    pub version: u8,
    #[serde(default)]
    pub layout: AppLayout,
    #[serde(default)]
    pub repository_defaults: RepositoryDefaults,
    pub repo_registry: Vec<RegisteredRepo>,
    pub tasks: Vec<Task>,
    pub selection: AppSelection,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppLayout {
    #[serde(default)]
    pub window: AppWindowLayout,
    #[serde(default)]
    pub side_panels: AppSidePanelLayout,
}

impl Default for AppLayout {
    fn default() -> Self {
        Self {
            window: AppWindowLayout::default(),
            side_panels: AppSidePanelLayout::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppWindowLayout {
    #[serde(default = "default_window_width")]
    pub width: u16,
    #[serde(default = "default_window_height")]
    pub height: u16,
    pub x: Option<i32>,
    pub y: Option<i32>,
}

impl Default for AppWindowLayout {
    fn default() -> Self {
        Self {
            width: default_window_width(),
            height: default_window_height(),
            x: None,
            y: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSidePanelLayout {
    #[serde(default = "default_left_side_panel_width")]
    pub left_width: u16,
    #[serde(default = "default_right_side_panel_width")]
    pub right_width: u16,
}

impl Default for AppSidePanelLayout {
    fn default() -> Self {
        Self {
            left_width: default_left_side_panel_width(),
            right_width: default_right_side_panel_width(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryDefaults {
    #[serde(default = "default_worktree_base_path")]
    pub worktree_base_path: String,
}

impl Default for RepositoryDefaults {
    fn default() -> Self {
        Self {
            worktree_base_path: default_worktree_base_path(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisteredRepo {
    pub id: String,
    pub name: String,
    pub org: Option<String>,
    pub description: Option<String>,
    pub source: RepoSource,
    pub branches: Vec<String>,
    pub default_branch: String,
    pub worktree_base_path: Option<String>,
    pub github_account: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoSource {
    pub kind: RepoSourceKind,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RepoSourceKind {
    Local,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub id: String,
    pub name: String,
    pub color: String,
    pub repos: Vec<TaskRepo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskRepo {
    pub id: String,
    pub registered_repo_id: String,
    pub base_branch: String,
    pub branch: String,
    pub worktree_path: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSelection {
    pub task_id: Option<String>,
    pub task_repo_id_by_task_id: HashMap<String, Option<String>>,
    pub expanded_task_ids: Vec<String>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            version: APP_STATE_VERSION,
            layout: AppLayout::default(),
            repository_defaults: RepositoryDefaults::default(),
            repo_registry: Vec::new(),
            tasks: Vec::new(),
            selection: AppSelection::default(),
        }
    }
}

#[tauri::command]
pub fn load_app_state(app: AppHandle) -> Result<AppState, String> {
    let path = app_state_path(&app)?;

    if !path.exists() {
        return Ok(AppState::default());
    }

    let data = fs::read_to_string(path).map_err(|error| error.to_string())?;
    let state: AppState = serde_json::from_str(&data).map_err(|error| error.to_string())?;

    if state.version != APP_STATE_VERSION {
        return Err(format!("unsupported app state version {}", state.version));
    }

    Ok(state)
}

#[tauri::command]
pub fn save_app_state(app: AppHandle, state: AppState) -> Result<(), String> {
    if state.version != APP_STATE_VERSION {
        return Err(format!("unsupported app state version {}", state.version));
    }

    let path = app_state_path(&app)?;

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }

    let data = serde_json::to_string_pretty(&state).map_err(|error| error.to_string())?;
    fs::write(path, data).map_err(|error| error.to_string())
}

pub fn restore_window_layout(app: &AppHandle) -> Result<(), String> {
    let path = app_state_path(app)?;

    if !path.exists() {
        return Ok(());
    }

    let data = fs::read_to_string(path).map_err(|error| error.to_string())?;
    let state: AppState = serde_json::from_str(&data).map_err(|error| error.to_string())?;

    if state.version != APP_STATE_VERSION {
        return Ok(());
    }

    let window = app
        .get_webview_window("main")
        .ok_or_else(|| "main window is missing".to_string())?;
    let width = state
        .layout
        .window
        .width
        .clamp(MIN_WINDOW_WIDTH, MAX_WINDOW_WIDTH);
    let height = state
        .layout
        .window
        .height
        .clamp(MIN_WINDOW_HEIGHT, MAX_WINDOW_HEIGHT);

    window
        .set_size(LogicalSize::new(f64::from(width), f64::from(height)))
        .map_err(|error| error.to_string())?;

    if let (Some(x), Some(y)) = (state.layout.window.x, state.layout.window.y) {
        window
            .set_position(LogicalPosition::new(f64::from(x), f64::from(y)))
            .map_err(|error| error.to_string())?;
    }

    Ok(())
}

fn app_state_path(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_data_dir()
        .map(|dir| dir.join(APP_STATE_FILE))
        .map_err(|error| error.to_string())
}

fn default_worktree_base_path() -> String {
    DEFAULT_WORKTREE_BASE_PATH.into()
}

fn default_window_width() -> u16 {
    1200
}

fn default_window_height() -> u16 {
    780
}

fn default_left_side_panel_width() -> u16 {
    264
}

fn default_right_side_panel_width() -> u16 {
    300
}

#[cfg(test)]
mod tests {
    use super::AppState;

    #[test]
    fn legacy_state_gets_default_layout() {
        let state: AppState = serde_json::from_str(
            r#"{
              "version": 1,
              "repoRegistry": [],
              "tasks": [],
              "selection": {
                "taskId": null,
                "taskRepoIdByTaskId": {},
                "expandedTaskIds": []
              }
            }"#,
        )
        .expect("legacy state should load");

        assert_eq!(state.layout.window.width, 1200);
        assert_eq!(state.layout.window.height, 780);
        assert_eq!(state.layout.window.x, None);
        assert_eq!(state.layout.window.y, None);
        assert_eq!(state.layout.side_panels.left_width, 264);
        assert_eq!(state.layout.side_panels.right_width, 300);
    }
}
