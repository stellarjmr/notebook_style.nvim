// Discover Jupyter kernels by scanning kernelspec directories.
// Reference: https://jupyter-client.readthedocs.io/en/stable/kernels.html

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KernelSpec {
    /// Kernel name (directory name under kernels/)
    pub name: String,
    /// Path to the kernel directory containing kernel.json
    pub path: PathBuf,
    /// Argv to launch the kernel (with {connection_file} placeholder)
    pub argv: Vec<String>,
    pub display_name: String,
    pub language: String,
    #[serde(default)]
    pub interrupt_mode: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub metadata: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct KernelJson {
    argv: Vec<String>,
    display_name: String,
    language: String,
    #[serde(default)]
    interrupt_mode: Option<String>,
    #[serde(default)]
    env: HashMap<String, String>,
    #[serde(default)]
    metadata: serde_json::Value,
}

/// Standard Jupyter kernelspec dirs in priority order.
fn search_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(s) = std::env::var("JUPYTER_PATH") {
        for p in s.split(':') {
            dirs.push(PathBuf::from(p).join("kernels"));
        }
    }
    if let Some(home) = dirs::home_dir() {
        // macOS user data
        dirs.push(home.join("Library/Jupyter/kernels"));
        // Linux user data
        if let Some(data) = dirs::data_dir() {
            dirs.push(data.join("jupyter/kernels"));
        }
        // Conda env shadow
        if let Ok(prefix) = std::env::var("CONDA_PREFIX") {
            dirs.push(PathBuf::from(&prefix).join("share/jupyter/kernels"));
        }
        if let Ok(prefix) = std::env::var("VIRTUAL_ENV") {
            dirs.push(PathBuf::from(&prefix).join("share/jupyter/kernels"));
        }
    }
    // System
    dirs.push(PathBuf::from("/usr/share/jupyter/kernels"));
    dirs.push(PathBuf::from("/usr/local/share/jupyter/kernels"));
    dirs.push(PathBuf::from("/opt/homebrew/share/jupyter/kernels"));
    dirs
}

pub fn discover_all() -> Vec<KernelSpec> {
    let mut found: HashMap<String, KernelSpec> = HashMap::new();
    for dir in search_dirs() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for ent in entries.flatten() {
            let path = ent.path();
            if !path.is_dir() {
                continue;
            }
            let name = match path.file_name().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            // First-found-wins (search dirs are ordered by priority)
            if found.contains_key(&name) {
                continue;
            }
            if let Ok(spec) = load_one(&name, &path) {
                found.insert(name, spec);
            }
        }
    }
    let mut list: Vec<KernelSpec> = found.into_values().collect();
    list.sort_by(|a, b| a.display_name.cmp(&b.display_name));
    list
}

pub fn discover_by_name(name: &str) -> Option<KernelSpec> {
    discover_all().into_iter().find(|s| s.name == name)
}

/// Resolve a kernelspec name with sensible fallbacks.
///
/// Match priority:
///   1. Exact name match (`julia-1.12` → `julia-1.12`).
///   2. Prefix-with-dash match (`julia` → `julia-1.12` if installed).
///      Catches notebooks saved without a version suffix.
///   3. Language match (notebook says language="julia" but no exact / prefix
///      kernel found → use the first installed kernel whose language matches).
///      Lets a notebook from a 1.10 user open cleanly on a machine with only
///      1.12 installed, even if name and prefix both differ.
/// Returns None if nothing matches.
pub fn discover_with_fallback(name: &str, language: Option<&str>) -> Option<KernelSpec> {
    let all = discover_all();
    if let Some(s) = all.iter().find(|s| s.name == name) {
        return Some(s.clone());
    }
    let prefix = format!("{name}-");
    if let Some(s) = all.iter().find(|s| s.name.starts_with(&prefix)) {
        return Some(s.clone());
    }
    if let Some(lang) = language {
        let lang_lower = lang.to_lowercase();
        if let Some(s) = all.iter().find(|s| s.language.to_lowercase() == lang_lower) {
            return Some(s.clone());
        }
    }
    None
}

fn load_one(name: &str, dir: &PathBuf) -> Result<KernelSpec> {
    let kj_path = dir.join("kernel.json");
    let raw = std::fs::read_to_string(&kj_path)
        .with_context(|| format!("reading {}", kj_path.display()))?;
    let kj: KernelJson =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", kj_path.display()))?;
    Ok(KernelSpec {
        name: name.to_string(),
        path: dir.clone(),
        argv: kj.argv,
        display_name: kj.display_name,
        language: kj.language,
        interrupt_mode: kj.interrupt_mode,
        env: kj.env,
        metadata: kj.metadata,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discover_does_not_panic() {
        let _ = discover_all();
    }
}
