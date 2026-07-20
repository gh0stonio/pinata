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
    #[serde(default)]
    pub terminal: TaskTerminal,
    pub repos: Vec<TaskRepo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskTerminal {
    pub id: String,
    pub cwd: String,
}

impl Default for TaskTerminal {
    fn default() -> Self {
        Self {
            id: String::new(),
            cwd: "~".into(),
        }
    }
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
    #[serde(default)]
    pub surface_by_task_id: HashMap<String, TaskSurfaceSelection>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub task_repo_id_by_task_id: HashMap<String, Option<String>>,
    pub expanded_task_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum TaskSurfaceSelection {
    TaskTerminal,
    Repo {
        #[serde(rename = "taskRepoId")]
        task_repo_id: String,
    },
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

    Ok(normalize_app_state(state))
}

#[tauri::command]
pub fn save_app_state(app: AppHandle, state: AppState) -> Result<(), String> {
    if state.version != APP_STATE_VERSION {
        return Err(format!("unsupported app state version {}", state.version));
    }

    let state = normalize_app_state(state);
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
    let state = normalize_app_state(state);

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

fn normalize_app_state(mut state: AppState) -> AppState {
    let task_ids: Vec<String> = state.tasks.iter().map(|task| task.id.clone()).collect();
    let mut surface_by_task_id = HashMap::new();

    for task in &mut state.tasks {
        if task.terminal.id.trim().is_empty() {
            task.terminal.id = format!("task-terminal-{}", task.id);
        }

        if task.terminal.cwd.trim().is_empty() {
            task.terminal.cwd = "~".into();
        }

        let repo_ids: Vec<&str> = task.repos.iter().map(|repo| repo.id.as_str()).collect();
        let legacy_repo_id = state
            .selection
            .task_repo_id_by_task_id
            .get(&task.id)
            .and_then(|repo_id| repo_id.as_deref());

        let surface = match state.selection.surface_by_task_id.get(&task.id) {
            Some(TaskSurfaceSelection::Repo { task_repo_id })
                if repo_ids.contains(&task_repo_id.as_str()) =>
            {
                TaskSurfaceSelection::Repo {
                    task_repo_id: task_repo_id.clone(),
                }
            }
            Some(TaskSurfaceSelection::TaskTerminal) => TaskSurfaceSelection::TaskTerminal,
            _ if legacy_repo_id.is_some_and(|repo_id| repo_ids.contains(&repo_id)) => {
                TaskSurfaceSelection::Repo {
                    task_repo_id: legacy_repo_id.unwrap().to_string(),
                }
            }
            _ => TaskSurfaceSelection::TaskTerminal,
        };

        surface_by_task_id.insert(task.id.clone(), surface);
    }

    state.selection.task_id = state
        .selection
        .task_id
        .filter(|task_id| task_ids.contains(task_id))
        .or_else(|| task_ids.first().cloned());
    state.selection.surface_by_task_id = surface_by_task_id;
    state
        .selection
        .expanded_task_ids
        .retain(|task_id| task_ids.contains(task_id));
    state.selection.task_repo_id_by_task_id.clear();

    state
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
    use super::{normalize_app_state, AppState, TaskSurfaceSelection};

    #[test]
    fn legacy_state_gets_default_layout() {
        let state: AppState = serde_json::from_str(
            r##"{
              "version": 1,
              "repoRegistry": [],
              "tasks": [],
              "selection": {
                "taskId": null,
                "taskRepoIdByTaskId": {},
                "expandedTaskIds": []
              }
            }"##,
        )
        .expect("legacy state should load");

        assert_eq!(state.layout.window.width, 1200);
        assert_eq!(state.layout.window.height, 780);
        assert_eq!(state.layout.window.x, None);
        assert_eq!(state.layout.window.y, None);
        assert_eq!(state.layout.side_panels.left_width, 264);
        assert_eq!(state.layout.side_panels.right_width, 300);
    }

    #[test]
    fn legacy_repo_selection_migrates_to_surface_selection() {
        let state: AppState = serde_json::from_str(
            r##"{
              "version": 1,
              "repoRegistry": [],
              "tasks": [
                {
                  "id": "task-one",
                  "name": "Investigate",
                  "color": "#8f989d",
                  "repos": [
                    {
                      "id": "task-repo-one",
                      "registeredRepoId": "repo-one",
                      "baseBranch": "main",
                      "branch": "feat/task-one",
                      "worktreePath": "/tmp/task-one"
                    }
                  ]
                },
                {
                  "id": "task-two",
                  "name": "Scratch",
                  "color": "#8f989d",
                  "repos": []
                }
              ],
              "selection": {
                "taskId": "task-one",
                "taskRepoIdByTaskId": {
                  "task-one": "task-repo-one",
                  "task-two": null
                },
                "expandedTaskIds": ["task-one", "missing-task"]
              }
            }"##,
        )
        .expect("legacy state should load");

        let state = normalize_app_state(state);

        assert_eq!(state.tasks[0].terminal.id, "task-terminal-task-one");
        assert_eq!(state.tasks[0].terminal.cwd, "~");
        assert_eq!(state.tasks[1].terminal.id, "task-terminal-task-two");
        assert!(state.selection.task_repo_id_by_task_id.is_empty());
        assert_eq!(state.selection.expanded_task_ids, vec!["task-one"]);

        match state.selection.surface_by_task_id.get("task-one") {
            Some(TaskSurfaceSelection::Repo { task_repo_id }) => {
                assert_eq!(task_repo_id, "task-repo-one");
            }
            _ => panic!("expected repo surface"),
        }

        assert!(matches!(
            state.selection.surface_by_task_id.get("task-two"),
            Some(TaskSurfaceSelection::TaskTerminal)
        ));
    }
}
