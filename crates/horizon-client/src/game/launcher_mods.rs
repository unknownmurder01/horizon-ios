//! `launcher-mod {json}`: the phone launcher's Mods page (packaging/ios/Launcher/Mods.swift), answered.
//!
//! The launcher downloads files; the game decides whether they are good. Everything that must be right
//! is here, using the same checks as the desktop launcher (`horizon_mods::index::check_file`): the file's
//! size and SHA-256 are the index's, it isn't revoked, its minisign signature matches the project's key,
//! and its `horizon-mod.toml` says what the index says.
//!
//! Only content mods (`.hmod` made of data and assets) are installed. A registry file that carries code
//! (any capability beyond `registries`) is refused: the game doesn't run it, and iOS could not load it
//! anyway. Native mods (`.hnmod`) are built from source by the desktop launcher and are not offered.
//!
//! Actions (`action` in the JSON):
//! - `install` `{id, index, file, version?}`: `index` is the downloaded `index.json`, `file` the downloaded
//!   mod, both under the game folder; it is checked, moved to `horizon-mods/<id>.hmod` and turned on.
//! - `list`: the mods in `horizon-mods/` with whether each is on.
//! - `set` `{id, on}`: turn a mod on or off in `horizon-mods.txt`.
//! - `remove` `{id}`: delete the mod and turn it off.
//!
//! The game reads its mods once, when it starts, so every answer says `restart: true`.
use horizon_mods::{
    Capability,
    index::{self, Index, Kind, Trust},
};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// Where the game keeps mods, beside `options.txt`.
const MODS_DIR: &str = "horizon-mods";
/// The switches: one `mod.<id>:true` line for each mod that is on.
const MODS_LIST: &str = "horizon-mods.txt";
/// The only folder the launcher may hand files from.
const STAGING: &str = "mod-browser";

/// `launcher-mod`'s arguments: the JSON after the word.
pub(super) fn args(line: &str) -> Value {
    line.trim_start()
        .strip_prefix("launcher-mod")
        .and_then(|rest| serde_json::from_str(rest).ok())
        .unwrap_or_default()
}

/// Do what `args` asks in the game folder `home`.
pub(super) fn run(home: &Path, args: &Value) -> Result<Value, String> {
    let text = |key: &str| args[key].as_str().unwrap_or_default();
    let id = text("id");
    match text("action") {
        "install" => install(home, id, text("version"), text("index"), text("file")),
        "list" => list(home),
        "set" => {
            let on = args["on"].as_bool().ok_or("launcher-mod set needs \"on\"")?;
            known(id)?;
            set_enabled(home, id, on)?;
            Ok(json!({ "ok": true, "id": id, "on": on, "restart": true }))
        }
        "remove" => remove(home, id),
        other => Err(format!(
            "launcher-mod: no action {other:?} (install, list, set, remove)"
        )),
    }
}

fn known(id: &str) -> Result<(), String> {
    match index::valid_id(id) {
        true => Ok(()),
        false => Err(format!("{id:?} is not a mod id ([a-z0-9_], at most 64)")),
    }
}

/// `path`, which must be a file inside the launcher's staging folder of `home`: the launcher is a
/// separate program, and what it names is not trusted to be anywhere else.
fn staged(home: &Path, path: &str) -> Result<PathBuf, String> {
    let root = home
        .join(STAGING)
        .canonicalize()
        .map_err(|_| "nothing was downloaded".to_owned())?;
    let file = Path::new(path)
        .canonicalize()
        .map_err(|e| format!("{path}: {e}"))?;
    match file.starts_with(&root) && file.is_file() {
        true => Ok(file),
        false => Err("that file isn't one the launcher downloaded".into()),
    }
}

fn install(
    home: &Path,
    id: &str,
    wanted: &str,
    index_path: &str,
    file_path: &str,
) -> Result<Value, String> {
    known(id)?;
    let index_file = staged(home, index_path)?;
    let file = staged(home, file_path)?;
    let text = fs::read_to_string(&index_file).map_err(|e| format!("the mod index: {e}"))?;
    let index = Index::parse(&text)?;
    let project = index
        .project(id)
        .ok_or_else(|| format!("{id} isn't in Horizon's mod registry"))?;
    if project.kind != Kind::Mod {
        return Err(format!(
            "{} is a {}, which this page doesn't install",
            project.name,
            project.kind.name()
        ));
    }
    let version = match wanted {
        "" => index
            .installable(
                project,
                horizon_core::version::VERSION_ID,
                horizon_mods::api_level::LEVEL,
            )
            .ok_or_else(|| {
                format!(
                    "{} has no version for Minecraft {}",
                    project.name,
                    horizon_core::version::VERSION_ID
                )
            })?,
        wanted => project
            .versions
            .iter()
            .find(|v| v.version == wanted)
            .ok_or_else(|| format!("{} has no version {wanted}", project.name))?,
    };
    if version.game != horizon_core::version::VERSION_ID {
        return Err(format!(
            "{} {} is for Minecraft {}, not {}",
            project.name,
            version.version,
            version.game,
            horizon_core::version::VERSION_ID
        ));
    }
    if needs_code(version) {
        return Err(format!(
            "{} {} carries code, which Horizon doesn't run on iPhone and iPad",
            project.name, version.version
        ));
    }
    if !version.file.name.ends_with(".hmod") {
        return Err(format!("{} isn't a .hmod", version.file.name));
    }
    // The size, hash, revocation, signature and manifest checks of the desktop launcher.
    let trust = index::check_file(&index, project, version, &file).inspect_err(|_| {
        let _ = fs::remove_file(&file);
    })?;

    let dir = home.join(MODS_DIR);
    if dir.join(id).exists() {
        return Err(format!(
            "A mod folder named {id} is already in {MODS_DIR}: move it away first."
        ));
    }
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let target = dir.join(format!("{id}.hmod"));
    fs::rename(&file, &target).map_err(|e| format!("{}: {e}", target.display()))?;
    set_enabled(home, id, true)?;
    Ok(json!({
        "ok": true,
        "id": id,
        "name": project.name,
        "version": version.version,
        "trust": match trust { Trust::Verified => "verified", Trust::Unsigned => "unsigned" },
        "restart": true,
    }))
}

/// Whether a version carries code: any capability beyond adding blocks, items and effects.
fn needs_code(version: &index::Version) -> bool {
    version
        .capabilities
        .iter()
        .any(|c| *c != Capability::Registries)
}

fn list(home: &Path) -> Result<Value, String> {
    let dir = home.join(MODS_DIR);
    let mut mods = Vec::new();
    for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let (id, folder) = match name.strip_suffix(".hmod") {
            Some(id) if path.is_file() => (id.to_owned(), false),
            None if path.join("horizon-mod.toml").is_file() => (name.clone(), true),
            _ => continue,
        };
        mods.push(json!({
            "id": id,
            "file": name,
            "folder": folder,
            "enabled": is_enabled(home, &id),
        }));
    }
    mods.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    Ok(json!({ "mods": mods }))
}

fn remove(home: &Path, id: &str) -> Result<Value, String> {
    known(id)?;
    let dir = home.join(MODS_DIR);
    let (file, folder) = (dir.join(format!("{id}.hmod")), dir.join(id));
    if !file.is_file() && !folder.is_dir() {
        return Err(format!("{id} isn't installed"));
    }
    // Off first: a failed delete then leaves a mod that is off, not one that is on and half gone.
    set_enabled(home, id, false)?;
    if file.is_file() {
        fs::remove_file(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    }
    if folder.is_dir() {
        fs::remove_dir_all(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    }
    Ok(json!({ "ok": true, "id": id, "restart": true }))
}

/// Whether mod `id` is on in `horizon-mods.txt`.
fn is_enabled(home: &Path, id: &str) -> bool {
    let key = format!("mod.{id}");
    fs::read_to_string(home.join(MODS_LIST))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once(':'))
        .any(|(k, v)| k.trim() == key && v.trim() == "true")
}

/// Turns mod `id` on (or off) in `horizon-mods.txt`, keeping every other line.
fn set_enabled(home: &Path, id: &str, on: bool) -> Result<(), String> {
    let path = home.join(MODS_LIST);
    let text = fs::read_to_string(&path).unwrap_or_default();
    let key = format!("mod.{id}");
    let mut lines: Vec<String> = text
        .lines()
        .filter(|l| l.split_once(':').is_none_or(|(k, _)| k.trim() != key))
        .map(str::to_owned)
        .collect();
    if on {
        lines.push(format!("{key}:true"));
    }
    let mut out = lines.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    fs::write(&path, out).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("horizon-launcher-mods-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn switches_keep_other_lines() {
        let home = home("switch");
        fs::write(home.join(MODS_LIST), "key.zoom.zoom:key.keyboard.c\nmod.a:true\n").unwrap();
        set_enabled(&home, "b", true).unwrap();
        set_enabled(&home, "a", false).unwrap();
        assert_eq!(
            fs::read_to_string(home.join(MODS_LIST)).unwrap(),
            "key.zoom.zoom:key.keyboard.c\nmod.b:true\n"
        );
        assert!(is_enabled(&home, "b"));
        assert!(!is_enabled(&home, "a"));
    }

    #[test]
    fn lists_files_and_folders_and_removes_them() {
        let home = home("list");
        let dir = home.join(MODS_DIR);
        fs::create_dir_all(dir.join("folder_mod")).unwrap();
        fs::write(dir.join("folder_mod/horizon-mod.toml"), "").unwrap();
        fs::write(dir.join("file_mod.hmod"), b"x").unwrap();
        fs::write(dir.join("readme.txt"), b"x").unwrap();
        set_enabled(&home, "file_mod", true).unwrap();
        let listed = list(&home).unwrap();
        let mods = listed["mods"].as_array().unwrap();
        assert_eq!(mods.len(), 2);
        assert_eq!(mods[0]["id"], "file_mod");
        assert_eq!(mods[0]["enabled"], true);
        assert_eq!(mods[1]["id"], "folder_mod");
        assert_eq!(mods[1]["enabled"], false);
        remove(&home, "file_mod").unwrap();
        remove(&home, "folder_mod").unwrap();
        assert!(list(&home).unwrap()["mods"].as_array().unwrap().is_empty());
        assert!(!is_enabled(&home, "file_mod"));
    }

    #[test]
    fn ids_cannot_name_paths() {
        let home = home("ids");
        for bad in ["", "../x", "a/b", "A", "x.hmod"] {
            assert!(remove(&home, bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn only_staged_files_are_installed() {
        let home = home("staged");
        fs::create_dir_all(home.join(STAGING)).unwrap();
        let outside = home.join("elsewhere.hmod");
        fs::write(&outside, b"x").unwrap();
        assert!(staged(&home, outside.to_str().unwrap()).is_err());
        let inside = home.join(STAGING).join("a.hmod");
        fs::write(&inside, b"x").unwrap();
        assert!(staged(&home, inside.to_str().unwrap()).is_ok());
        let traversal = format!("{}/{STAGING}/../elsewhere.hmod", home.display());
        assert!(staged(&home, &traversal).is_err());
    }

    #[test]
    fn arguments_come_after_the_word() {
        let a = args(r#"launcher-mod {"action":"set","id":"a","on":true}"#);
        assert_eq!(a["action"], "set");
        assert_eq!(a["on"], true);
        assert!(args("launcher-mod nonsense").is_null());
    }
}
