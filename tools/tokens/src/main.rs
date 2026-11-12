//! Generate the Calm Editorial design tokens for every platform.
//!
//! One JSON file holds the values. This tool writes the platform files, and
//! fails when a value or a binding is wrong.
//!
//! ```text
//! readlater-tokens            write every generated file
//! readlater-tokens --check    fail when a file is stale, write nothing
//! readlater-tokens --help     this text
//! ```
//!
//! Run it from anywhere inside the repo. The tool finds the root by walking up
//! to the directory that holds `design/tokens.json`.

mod emit;
mod model;
mod naming;
mod validate;
mod xml;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use model::Doc;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let check = match args
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        [] => false,
        ["--check"] => true,
        ["--help"] | ["-h"] => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        other => {
            eprintln!("unknown argument: {}", other.join(" "));
            eprintln!("{USAGE}");
            return ExitCode::FAILURE;
        }
    };

    match run(check) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("tokens: {error}");
            ExitCode::FAILURE
        }
    }
}

const USAGE: &str = "\
Usage: readlater-tokens [--check]

  (no flag)   write design/generated/* and the Swift tokens
  --check     fail when a generated file does not match design/tokens.json";

fn run(check: bool) -> Result<(), String> {
    let root = repo_root()?;
    let tokens = root.join("design/tokens.json");
    let text =
        fs::read_to_string(&tokens).map_err(|error| format!("{}: {error}", tokens.display()))?;
    let doc = Doc::parse(&text)?;
    validate::validate(&doc)?;

    let outputs = emit::emit_all(&doc)?;
    let mut stale: Vec<&str> = Vec::new();

    for output in &outputs {
        if output.path.ends_with(".xaml") {
            xml::check(&output.text).map_err(|error| format!("{}: {error}", output.path))?;
        }
        let path = root.join(output.path);
        let current = fs::read_to_string(&path).ok();
        if current.as_deref() == Some(output.text.as_str()) {
            continue;
        }
        if check {
            stale.push(output.path);
        } else {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)
                    .map_err(|error| format!("{}: {error}", parent.display()))?;
            }
            fs::write(&path, &output.text)
                .map_err(|error| format!("{}: {error}", path.display()))?;
        }
    }

    if check {
        if stale.is_empty() {
            println!("tokens: ok");
            return Ok(());
        }
        return Err(format!("stale: {}", stale.join(", ")));
    }
    println!("tokens: written");
    Ok(())
}

/// Walks up from the working directory to the repo root.
fn repo_root() -> Result<PathBuf, String> {
    let start = std::env::current_dir().map_err(|error| format!("current directory: {error}"))?;
    let mut dir: &Path = &start;
    loop {
        if dir.join("design/tokens.json").is_file() {
            return Ok(dir.to_path_buf());
        }
        dir = dir.parent().ok_or_else(|| {
            format!(
                "no design/tokens.json above {}; run this inside the read-later repo",
                start.display()
            )
        })?;
    }
}

#[cfg(test)]
mod repo_tests {
    use crate::{emit, model::Doc, validate, xml};
    use std::fs;
    use std::path::Path;

    fn root() -> &'static Path {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(Path::parent)
            .expect("tools/tokens is two levels below the root")
    }

    #[test]
    fn the_committed_files_match_the_source() {
        let text = fs::read_to_string(root().join("design/tokens.json")).expect("token file reads");
        let doc = Doc::parse(&text).expect("token file parses");
        validate::validate(&doc).expect("token file validates");

        let mut stale: Vec<&str> = Vec::new();
        for output in emit::emit_all(&doc).expect("emitters run") {
            let on_disk = fs::read_to_string(root().join(output.path)).unwrap_or_default();
            if on_disk != output.text {
                stale.push(output.path);
            }
        }
        assert!(stale.is_empty(), "stale: {stale:?}");
    }

    #[test]
    fn the_generated_xaml_is_well_formed() {
        let text = fs::read_to_string(root().join("design/tokens.json")).expect("token file reads");
        let doc = Doc::parse(&text).expect("token file parses");
        let outputs = emit::emit_all(&doc).expect("emitters run");
        let xaml = outputs
            .iter()
            .find(|output| output.path.ends_with(".xaml"))
            .expect("a xaml output");
        xml::check(&xaml.text).expect("xaml is well formed");
    }
}
