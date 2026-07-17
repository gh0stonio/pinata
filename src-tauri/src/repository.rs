use serde::Serialize;
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryInspection {
    pub name: String,
    pub org: Option<String>,
    pub path: String,
    pub branches: Vec<String>,
    pub default_branch: String,
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
    use super::{expand_home, parse_origin_org};

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
}
