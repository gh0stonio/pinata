use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fs, path::PathBuf};
use tauri::{AppHandle, Manager};

const APP_STATE_FILE: &str = "app-state.json";
const APP_STATE_VERSION: u8 = 1;
const DEFAULT_WORKTREE_BASE_PATH: &str = "~/.pinata/worktrees";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppState {
    pub version: u8,
    #[serde(default)]
    pub repository_defaults: RepositoryDefaults,
    pub repo_registry: Vec<RegisteredRepo>,
    pub tasks: Vec<Task>,
    pub selection: AppSelection,
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

fn app_state_path(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_data_dir()
        .map(|dir| dir.join(APP_STATE_FILE))
        .map_err(|error| error.to_string())
}

fn default_worktree_base_path() -> String {
    DEFAULT_WORKTREE_BASE_PATH.into()
}
