use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    thread,
};
use tauri::{AppHandle, Emitter};

const GIT_PROGRESS_EVENT: &str = "pinata://git-progress";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryInspection {
    pub name: String,
    pub org: Option<String>,
    pub path: String,
    pub branches: Vec<String>,
    pub default_branch: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskRepoGitOperation {
    pub source_path: String,
    pub base_branch: String,
    pub branch: String,
    pub worktree_path: String,
    pub progress_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct GitProgressEvent {
    progress_id: String,
    phase: String,
}

#[tauri::command]
pub fn inspect_repository(path: String) -> Result<RepositoryInspection, String> {
    let trimmed_path = path.trim();

    if trimmed_path.is_empty() {
        return Err("repository path is required".into());
    }

    let input_path = expand_home(trimmed_path)?;

    if !input_path.exists() {
        return Err("repository path does not exist".into());
    }

    let root = git_stdout(&input_path, &["rev-parse", "--show-toplevel"])
        .map_err(|_| "selected folder is not a git repository".to_string())?;
    let root_path = fs::canonicalize(root.trim()).map_err(|error| error.to_string())?;
    let name = root_path
        .file_name()
        .and_then(|file_name| file_name.to_str())
        .ok_or_else(|| "could not infer repository name".to_string())?
        .to_string();
    let branches = read_branches(&root_path)?;
    let default_branch = read_default_branch(&root_path, &branches)?;
    let org = read_origin_org(&root_path).ok().flatten();

    Ok(RepositoryInspection {
        name: name.clone(),
        org,
        path: root_path.to_string_lossy().to_string(),
        branches,
        default_branch,
    })
}

#[tauri::command]
pub async fn create_task_repo_worktree(
    app: AppHandle,
    input: TaskRepoGitOperation,
) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || create_task_repo_worktree_sync(Some(app), input))
        .await
        .map_err(|error| error.to_string())?
}

fn create_task_repo_worktree_sync(
    app: Option<AppHandle>,
    input: TaskRepoGitOperation,
) -> Result<String, String> {
    let source_path = expand_home(input.source_path.trim())?;
    let worktree_path = expand_home(input.worktree_path.trim())?;
    let branch = input.branch.trim();
    let base_branch = input.base_branch.trim();

    if branch.is_empty() || base_branch.is_empty() || input.worktree_path.trim().is_empty() {
        return Err("branch, base branch, and worktree path are required".into());
    }

    ensure_git_repo(&source_path)?;

    if git_branch_exists(&source_path, branch)? {
        return Err(format!("branch already exists: {branch}"));
    }

    if worktree_path.exists() {
        return Err(format!(
            "worktree path already exists: {}",
            worktree_path.to_string_lossy()
        ));
    }

    let start_point = git_start_point(&app, &input.progress_id, &source_path, base_branch)?;

    if let Some(parent) = worktree_path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }

    let worktree_path_str = worktree_path
        .to_str()
        .ok_or_else(|| "worktree path is not valid UTF-8".to_string())?;
    emit_git_phase(&app, &input.progress_id, "Preparing worktree");

    let add_result = git_success_streaming(
        &app,
        input.progress_id.as_deref(),
        &source_path,
        &[
            "worktree",
            "add",
            "-b",
            branch,
            worktree_path_str,
            &start_point,
        ],
    );

    if let Err(error) = add_result {
        if worktree_path.exists() {
            let _ = git_success(
                &source_path,
                &["worktree", "remove", "--force", worktree_path_str],
            );
        }

        if git_branch_exists(&source_path, branch).unwrap_or(false) {
            let _ = git_success(&source_path, &["branch", "-D", branch]);
        }

        return Err(error);
    }

    Ok(fs::canonicalize(&worktree_path)
        .unwrap_or(worktree_path)
        .to_string_lossy()
        .to_string())
}

#[tauri::command]
pub async fn delete_task_repo_worktree(input: TaskRepoGitOperation) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || delete_task_repo_worktree_sync(input))
        .await
        .map_err(|error| error.to_string())?
}

fn delete_task_repo_worktree_sync(input: TaskRepoGitOperation) -> Result<(), String> {
    let source_path = expand_home(input.source_path.trim())?;
    let worktree_path = expand_home(input.worktree_path.trim())?;
    let branch = input.branch.trim();

    if branch.is_empty() {
        return Err("branch is required".into());
    }

    ensure_git_repo(&source_path)?;

    if worktree_path.exists() {
        git_success(
            &source_path,
            &[
                "worktree",
                "remove",
                "--force",
                worktree_path
                    .to_str()
                    .ok_or_else(|| "worktree path is not valid UTF-8".to_string())?,
            ],
        )?;
    }

    if git_branch_exists(&source_path, branch)? {
        git_success(&source_path, &["branch", "-D", branch])?;
    }

    Ok(())
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

fn ensure_git_repo(path: &Path) -> Result<(), String> {
    git_success(path, &["rev-parse", "--show-toplevel"])
        .map_err(|_| "selected folder is not a git repository".to_string())
}

fn git_stdout(path: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .map_err(|error| format!("failed to run git: {error}"))?;

    if output.status.success() {
        return String::from_utf8(output.stdout).map_err(|error| error.to_string());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(if stderr.is_empty() {
        "git command failed".into()
    } else {
        stderr
    })
}

fn git_success(path: &Path, args: &[&str]) -> Result<(), String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .map_err(|error| format!("failed to run git: {error}"))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(if stderr.is_empty() {
        "git command failed".into()
    } else {
        stderr
    })
}

fn git_success_streaming(
    app: &Option<AppHandle>,
    progress_id: Option<&str>,
    path: &Path,
    args: &[&str],
) -> Result<(), String> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("failed to run git: {error}"))?;
    let current_phase = Arc::new(Mutex::new(None::<String>));
    let error_lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let mut readers = Vec::new();

    if let Some(stdout) = child.stdout.take() {
        readers.push(read_git_output(
            stdout,
            app.clone(),
            progress_id.map(ToOwned::to_owned),
            Arc::clone(&current_phase),
            Arc::clone(&error_lines),
            false,
        ));
    }

    if let Some(stderr) = child.stderr.take() {
        readers.push(read_git_output(
            stderr,
            app.clone(),
            progress_id.map(ToOwned::to_owned),
            Arc::clone(&current_phase),
            Arc::clone(&error_lines),
            true,
        ));
    }

    let status = child
        .wait()
        .map_err(|error| format!("failed to wait for git: {error}"))?;

    for reader in readers {
        let _ = reader.join();
    }

    if status.success() {
        return Ok(());
    }

    let stderr = error_lines
        .lock()
        .ok()
        .map(|lines| {
            lines
                .iter()
                .rev()
                .take(8)
                .cloned()
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join("\n")
        })
        .filter(|message| !message.trim().is_empty());

    Err(stderr.unwrap_or_else(|| "git command failed".into()))
}

fn read_git_output<R: Read + Send + 'static>(
    mut reader: R,
    app: Option<AppHandle>,
    progress_id: Option<String>,
    current_phase: Arc<Mutex<Option<String>>>,
    error_lines: Arc<Mutex<Vec<String>>>,
    capture_errors: bool,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut read_buffer = [0_u8; 1024];
        let mut line_buffer = Vec::new();

        loop {
            match reader.read(&mut read_buffer) {
                Ok(0) => break,
                Ok(count) => {
                    for byte in &read_buffer[..count] {
                        if *byte == b'\n' || *byte == b'\r' {
                            handle_git_output_line(
                                &line_buffer,
                                &app,
                                &progress_id,
                                &current_phase,
                                &error_lines,
                                capture_errors,
                            );
                            line_buffer.clear();
                        } else {
                            line_buffer.push(*byte);
                        }
                    }
                }
                Err(_) => break,
            }
        }

        handle_git_output_line(
            &line_buffer,
            &app,
            &progress_id,
            &current_phase,
            &error_lines,
            capture_errors,
        );
    })
}

fn handle_git_output_line(
    bytes: &[u8],
    app: &Option<AppHandle>,
    progress_id: &Option<String>,
    current_phase: &Arc<Mutex<Option<String>>>,
    error_lines: &Arc<Mutex<Vec<String>>>,
    capture_errors: bool,
) {
    let line = String::from_utf8_lossy(bytes).trim().to_string();

    if line.is_empty() {
        return;
    }

    if capture_errors {
        if let Ok(mut lines) = error_lines.lock() {
            lines.push(line.clone());

            if lines.len() > 32 {
                lines.remove(0);
            }
        }
    }

    if let Some(phase) = git_progress_phase(&line) {
        emit_git_phase_dedup(app, progress_id, current_phase, &phase);
    }
}

fn emit_git_phase(app: &Option<AppHandle>, progress_id: &Option<String>, phase: &str) {
    let current_phase = Arc::new(Mutex::new(None::<String>));
    emit_git_phase_dedup(app, progress_id, &current_phase, phase);
}

fn emit_git_phase_dedup(
    app: &Option<AppHandle>,
    progress_id: &Option<String>,
    current_phase: &Arc<Mutex<Option<String>>>,
    phase: &str,
) {
    let Some(app) = app else {
        return;
    };
    let Some(progress_id) = progress_id else {
        return;
    };

    if let Ok(mut current) = current_phase.lock() {
        if current.as_deref() == Some(phase) {
            return;
        }

        *current = Some(phase.to_string());
    }

    let _ = app.emit(
        GIT_PROGRESS_EVENT,
        GitProgressEvent {
            progress_id: progress_id.clone(),
            phase: phase.into(),
        },
    );
}

fn git_progress_phase(line: &str) -> Option<String> {
    if line.starts_with("Preparing worktree") {
        return Some("Preparing worktree".into());
    }

    if line.starts_with("Updating files:") {
        return Some("Updating files".into());
    }

    if line.contains("[post-checkout]") || line.contains("post-checkout") {
        return Some("Repository hooks".into());
    }

    if line.contains("installing dependencies") || line.contains("Installing dependencies") {
        return Some("Installing dependencies".into());
    }

    if let Some((_, step)) = line.split_once('┌') {
        let step = normalize_hook_step(step);

        if !step.is_empty() {
            return Some(step);
        }
    }

    None
}

fn normalize_hook_step(step: &str) -> String {
    let step = step
        .trim()
        .trim_start_matches(|character: char| {
            !character.is_alphanumeric() && !character.is_whitespace()
        })
        .trim();

    if step.starts_with("Completed") {
        return String::new();
    }

    step.replace("the project", "project")
}

fn git_commit_exists(path: &Path, revision: &str) -> Result<bool, String> {
    git_status(
        path,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{revision}^{{commit}}"),
        ],
    )
}

fn git_branch_exists(path: &Path, branch: &str) -> Result<bool, String> {
    git_status(
        path,
        &[
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ],
    )
}

fn git_start_point(
    app: &Option<AppHandle>,
    progress_id: &Option<String>,
    path: &Path,
    base_branch: &str,
) -> Result<String, String> {
    let remote_branch = format!("origin/{base_branch}");

    if git_remote_exists(path, "origin")? {
        emit_git_phase(app, progress_id, "Fetching base branch");
        let refspec = format!("+refs/heads/{base_branch}:refs/remotes/origin/{base_branch}");

        git_success(path, &["fetch", "--no-tags", "origin", &refspec])
            .map_err(|error| format!("failed to update {base_branch} from origin: {error}"))?;

        if git_commit_exists(path, &remote_branch)? {
            return Ok(remote_branch);
        }

        return Err(format!(
            "base branch does not exist on origin: {base_branch}"
        ));
    }

    if git_commit_exists(path, base_branch)? {
        return Ok(base_branch.to_string());
    }

    Err(format!("base branch does not exist: {base_branch}"))
}

fn git_remote_exists(path: &Path, remote: &str) -> Result<bool, String> {
    git_status(path, &["config", "--get", &format!("remote.{remote}.url")])
}

fn git_status(path: &Path, args: &[&str]) -> Result<bool, String> {
    let status = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| format!("failed to run git: {error}"))?;

    match status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err("git command failed".into()),
    }
}

fn read_branches(path: &Path) -> Result<Vec<String>, String> {
    let output = git_stdout(path, &["branch", "--format=%(refname:short)"])?;
    let mut branches = output
        .lines()
        .map(str::trim)
        .filter(|branch| !branch.is_empty())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();

    if branches.is_empty() {
        branches.push("main".into());
    }

    branches.sort();
    branches.dedup();
    Ok(branches)
}

fn read_default_branch(path: &Path, branches: &[String]) -> Result<String, String> {
    if let Ok(branch) = git_stdout(
        path,
        &[
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
    ) {
        if let Some(default_branch) = branch.trim().strip_prefix("origin/") {
            return Ok(default_branch.to_string());
        }
    }

    if let Ok(branch) = git_stdout(path, &["branch", "--show-current"]) {
        let current = branch.trim();
        if !current.is_empty() {
            return Ok(current.to_string());
        }
    }

    Ok(branches.first().cloned().unwrap_or_else(|| "main".into()))
}

fn read_origin_org(path: &Path) -> Result<Option<String>, String> {
    let origin = git_stdout(path, &["remote", "get-url", "origin"])?;

    Ok(parse_origin_org(origin.trim()))
}

fn parse_origin_org(origin: &str) -> Option<String> {
    let repo = origin.trim_end_matches(".git");

    if let Some((_, path)) = repo.split_once("github.com:") {
        return path.split('/').next().map(ToOwned::to_owned);
    }

    if let Some((_, path)) = repo.split_once("github.com/") {
        return path.split('/').next().map(ToOwned::to_owned);
    }

    None
}

#[cfg(test)]
mod tests {
    use super::{
        create_task_repo_worktree_sync, delete_task_repo_worktree_sync, expand_home,
        git_branch_exists, git_progress_phase, git_stdout, parse_origin_org, TaskRepoGitOperation,
    };
    use std::{
        env, fs,
        os::unix::fs::PermissionsExt,
        path::{Path, PathBuf},
        process::Command,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn parses_github_org_from_ssh_and_https_remotes() {
        assert_eq!(
            parse_origin_org("git@github.com:gh0stonio/pinata.git"),
            Some("gh0stonio".into())
        );
        assert_eq!(
            parse_origin_org("https://github.com/openai/codex"),
            Some("openai".into())
        );
    }

    #[test]
    fn leaves_non_github_remotes_without_org() {
        assert_eq!(parse_origin_org("ssh://example.com/team/repo.git"), None);
    }

    #[test]
    fn expands_home_path() {
        assert!(expand_home("~/repo").expect("home path").ends_with("repo"));
    }

    #[test]
    fn maps_git_worktree_output_to_progress_phase() {
        assert_eq!(
            git_progress_phase("Preparing worktree (new branch 'feat/test')"),
            Some("Preparing worktree".into())
        );
        assert_eq!(
            git_progress_phase("Updating files: 42% (10/24)"),
            Some("Updating files".into())
        );
    }

    #[test]
    fn maps_hook_output_to_progress_phase() {
        assert_eq!(
            git_progress_phase("[post-checkout] Fresh worktree detected: installing dependencies"),
            Some("Repository hooks".into())
        );
        assert_eq!(
            git_progress_phase("➤ ┌ Linking the project"),
            Some("Linking project".into())
        );
        assert_eq!(git_progress_phase("➤ └ Completed in 1s"), None);
    }

    #[test]
    fn creates_and_deletes_task_worktree() {
        let root = temp_path("git-worktree");
        let repo = root.join("repo");
        let worktree = root.join("worktrees").join("abc123-task");

        fs::create_dir_all(&repo).expect("repo dir");
        git(&repo, &["init"]);
        git(&repo, &["config", "user.email", "pinata@example.com"]);
        git(&repo, &["config", "user.name", "Piñata"]);
        git(&repo, &["config", "commit.gpgsign", "false"]);
        fs::write(repo.join("README.md"), "hello").expect("write readme");
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "--no-verify", "-m", "init"]);

        let base_branch = git_stdout(&repo, &["branch", "--show-current"])
            .expect("current branch")
            .trim()
            .to_string();
        let input = TaskRepoGitOperation {
            source_path: repo.to_string_lossy().to_string(),
            base_branch,
            branch: "feat/abc123-task".into(),
            worktree_path: worktree.to_string_lossy().to_string(),
            progress_id: None,
        };

        create_task_repo_worktree_sync(None, input.clone()).expect("create worktree");
        assert!(worktree.exists());
        assert!(git_branch_exists(&repo, &input.branch).expect("branch exists"));

        delete_task_repo_worktree_sync(input.clone()).expect("delete worktree");
        assert!(!worktree.exists());
        assert!(!git_branch_exists(&repo, &input.branch).expect("branch deleted"));

        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn creates_task_worktree_from_latest_origin_branch() {
        let root = temp_path("git-worktree-origin");
        let remote = root.join("remote.git");
        let repo = root.join("repo");
        let updater = root.join("updater");
        let worktree = root.join("worktrees").join("abc123-task");

        fs::create_dir_all(&root).expect("root dir");
        git(
            &root,
            &["init", "--bare", remote.to_str().expect("remote path")],
        );
        git(
            &root,
            &["clone", remote.to_str().expect("remote path"), "repo"],
        );
        configure_test_repo(&repo);
        fs::write(repo.join("README.md"), "local\n").expect("write readme");
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "--no-verify", "-m", "initial"]);
        git(&repo, &["push", "-u", "origin", "HEAD"]);

        git(
            &root,
            &["clone", remote.to_str().expect("remote path"), "updater"],
        );
        configure_test_repo(&updater);
        fs::write(updater.join("README.md"), "remote update\n").expect("update readme");
        git(&updater, &["add", "."]);
        git(&updater, &["commit", "--no-verify", "-m", "remote update"]);
        git(&updater, &["push", "origin", "HEAD"]);

        let base_branch = git_stdout(&repo, &["branch", "--show-current"])
            .expect("current branch")
            .trim()
            .to_string();
        let input = TaskRepoGitOperation {
            source_path: repo.to_string_lossy().to_string(),
            base_branch,
            branch: "feat/abc123-task".into(),
            worktree_path: worktree.to_string_lossy().to_string(),
            progress_id: None,
        };

        create_task_repo_worktree_sync(None, input.clone()).expect("create worktree");

        let worktree_head = git_stdout(&worktree, &["rev-parse", "HEAD"]).expect("worktree head");
        let remote_branch = format!("origin/{}", input.base_branch);
        let remote_head =
            git_stdout(&repo, &["rev-parse", &remote_branch]).expect("remote branch head");
        assert_eq!(worktree_head.trim(), remote_head.trim());

        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn cleans_up_failed_task_worktree_creation() {
        let root = temp_path("git-worktree-failure");
        let repo = root.join("repo");
        let worktree = root.join("worktrees").join("abc123-task");

        fs::create_dir_all(&repo).expect("repo dir");
        git(&repo, &["init"]);
        git(&repo, &["config", "user.email", "pinata@example.com"]);
        git(&repo, &["config", "user.name", "Piñata"]);
        git(&repo, &["config", "commit.gpgsign", "false"]);
        fs::write(repo.join("README.md"), "hello").expect("write readme");
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "--no-verify", "-m", "init"]);

        let hook = repo.join(".git").join("hooks").join("post-checkout");
        fs::write(&hook, "#!/bin/sh\nexit 1\n").expect("write hook");
        let mut permissions = fs::metadata(&hook).expect("hook metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&hook, permissions).expect("hook permissions");

        let base_branch = git_stdout(&repo, &["branch", "--show-current"])
            .expect("current branch")
            .trim()
            .to_string();
        let input = TaskRepoGitOperation {
            source_path: repo.to_string_lossy().to_string(),
            base_branch,
            branch: "feat/abc123-task".into(),
            worktree_path: worktree.to_string_lossy().to_string(),
            progress_id: None,
        };

        assert!(create_task_repo_worktree_sync(None, input.clone()).is_err());
        assert!(!worktree.exists());
        assert!(!git_branch_exists(&repo, &input.branch).expect("branch deleted"));

        fs::remove_dir_all(root).ok();
    }

    fn temp_path(name: &str) -> PathBuf {
        env::temp_dir().join(format!(
            "pinata-{name}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ))
    }

    fn git(path: &Path, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(path)
            .args(args)
            .status()
            .expect("git runs");

        assert!(status.success(), "git {args:?} failed");
    }

    fn configure_test_repo(path: &Path) {
        git(path, &["config", "user.email", "pinata@example.com"]);
        git(path, &["config", "user.name", "Piñata"]);
        git(path, &["config", "commit.gpgsign", "false"]);
    }
}
