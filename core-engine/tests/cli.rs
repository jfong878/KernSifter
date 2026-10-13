//! End-to-end tests for the `core-engine-cli` binary: runs the compiled
//! executable and asserts on its JSON output and exit codes.

use std::process::Command;

/// Path of the compiled CLI binary, provided by cargo for integration tests.
const CLI: &str = env!("CARGO_BIN_EXE_core-engine-cli");

/// A path the host matrix must block (exists on every supported OS).
#[cfg(windows)]
fn protected_path() -> &'static str {
    r"C:\Windows\System32\cmd.exe"
}

#[cfg(not(windows))]
fn protected_path() -> &'static str {
    "/etc/passwd"
}

/// A path the host matrix must allow (need not exist — lexical validation).
#[cfg(windows)]
fn clean_path() -> &'static str {
    r"C:\Windows\Temp\audit-probe.tmp"
}

#[cfg(not(windows))]
fn clean_path() -> &'static str {
    "/tmp/audit-probe.tmp"
}

#[test]
fn prints_one_json_line_per_path_in_argument_order() {
    let out = Command::new(CLI)
        .arg(protected_path())
        .arg(clean_path())
        .output()
        .expect("run cli");
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));

    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 2, "expected one JSON line per path: {stdout}");

    let blocked: serde_json::Value = serde_json::from_str(lines[0]).expect("valid JSON");
    assert_eq!(blocked["path"], protected_path());
    assert_eq!(blocked["allowed"], false);
    assert!(blocked["reason"].is_string(), "{blocked}");
    assert!(blocked["rule"].is_string(), "{blocked}");

    let allowed: serde_json::Value = serde_json::from_str(lines[1]).expect("valid JSON");
    assert_eq!(allowed["path"], clean_path());
    assert_eq!(allowed["allowed"], true);
    assert!(allowed["reason"].is_null(), "{allowed}");
    assert!(allowed["rule"].is_null(), "{allowed}");
}

#[test]
fn pretty_mode_prints_a_single_json_array() {
    let out = Command::new(CLI)
        .arg("--pretty")
        .arg(protected_path())
        .output()
        .expect("run cli");
    assert!(out.status.success());
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let value: serde_json::Value = serde_json::from_str(&stdout).expect("valid JSON array");
    assert_eq!(value.as_array().map(Vec::len), Some(1));
    assert_eq!(value[0]["allowed"], false);
}

#[test]
fn strict_exits_nonzero_only_when_something_is_blocked() {
    let out = Command::new(CLI)
        .arg("--strict")
        .arg(protected_path())
        .output()
        .expect("run cli");
    assert_eq!(out.status.code(), Some(1), "blocked path must fail --strict");

    let out = Command::new(CLI)
        .arg("--strict")
        .arg(clean_path())
        .output()
        .expect("run cli");
    assert!(out.status.success(), "clean path must pass --strict");
}

#[test]
fn no_paths_is_a_usage_error() {
    let out = Command::new(CLI).output().expect("run cli");
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("no paths"),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn unknown_option_is_a_usage_error() {
    let out = Command::new(CLI)
        .arg("--bogus")
        .arg(protected_path())
        .output()
        .expect("run cli");
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("unknown option"));
}

// ── plan ──────────────────────────────────────────────────────────────────
//
// `plan` runs a real platform scan, so these tests only assert on the shape of
// the plan and on the argument handling — never on how much space a given
// machine happens to have. Anything machine-specific would make CI flaky.

/// A full scan is slow on a warm cache and very slow cold; give it room.
const PLAN_TIMEOUT_NOTE: &str = "plan walks every sanctioned root";

#[test]
fn plan_json_is_a_well_formed_cleanup_plan() {
    let out = Command::new(CLI)
        .args(["plan", "--json"])
        .output()
        .expect("run cli");
    assert!(
        out.status.success(),
        "{PLAN_TIMEOUT_NOTE}; stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let value: serde_json::Value =
        serde_json::from_slice(&out.stdout).expect("valid plan JSON");

    for key in ["platform", "generated_at_unix", "eligible", "skipped", "needs_elevation"] {
        assert!(value.get(key).is_some(), "plan JSON missing {key}: {value}");
    }
    assert!(value["platform"].is_string(), "{value}");
    assert!(value["needs_elevation"].is_boolean(), "{value}");

    let eligible = value["eligible"].as_array().expect("eligible is an array");
    let skipped = value["skipped"].as_array().expect("skipped is an array");

    // Every declined candidate must carry a reason — that is the whole point
    // of the `plan` surface: the executor never silently drops anything.
    for entry in skipped {
        assert!(entry["reason"].is_string(), "skipped entry without reason: {entry}");
        assert!(entry["path"].is_string(), "skipped entry without path: {entry}");
    }

    // Nothing the plan selected may carry a refused verdict, or the plan and
    // the protected-path matrix have drifted apart.
    for entry in eligible {
        assert_eq!(
            entry["verdict"]["allowed"], true,
            "plan selected a matrix-blocked path: {entry}"
        );
    }
}

#[test]
fn plan_partitions_candidates_with_no_overlap() {
    let out = Command::new(CLI)
        .args(["plan", "--json"])
        .output()
        .expect("run cli");
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    let value: serde_json::Value = serde_json::from_slice(&out.stdout).expect("valid plan JSON");

    let eligible = value["eligible"].as_array().expect("eligible is an array");
    let skipped = value["skipped"].as_array().expect("skipped is an array");

    let path_of = |e: &serde_json::Value| e["path"].as_str().expect("path is a string").to_owned();
    let eligible_paths: std::collections::HashSet<String> = eligible.iter().map(path_of).collect();
    let skipped_paths: std::collections::HashSet<String> = skipped.iter().map(path_of).collect();

    // A candidate is either actionable or declined, never both: an entry that
    // appears in both lists would let execution act on something the plan
    // says it refused.
    let overlap: Vec<&String> = eligible_paths.intersection(&skipped_paths).collect();
    assert!(overlap.is_empty(), "paths in both buckets: {overlap:?}");

    // Nor may the same path be listed twice within a bucket.
    assert_eq!(
        eligible_paths.len(),
        eligible.len(),
        "duplicate paths in the eligible set"
    );
    assert_eq!(
        skipped_paths.len(),
        skipped.len(),
        "duplicate paths in the skipped set"
    );
}

#[test]
fn plan_rejects_a_malformed_top_argument() {
    for bad in ["--category", "--top"] {
        let out = Command::new(CLI)
            .args(["plan", bad])
            .output()
            .expect("run cli");
        assert_eq!(out.status.code(), Some(2), "{bad} with no value must be a usage error");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("requires a"),
            "{bad} with no value: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

#[test]
fn plan_accepts_the_site_storage_category_by_name() {
    // Offline site data is opt-in by name; the CLI must accept the spelling
    // even though a smart clean never selects it.
    let out = Command::new(CLI)
        .args(["plan", "--category", "SiteStorage", "--top", "0"])
        .output()
        .expect("run cli");
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn plan_rejects_an_unknown_category() {
    let out = Command::new(CLI)
        .args(["plan", "--category", "NotACategory"])
        .output()
        .expect("run cli");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("unknown category"), "stderr: {stderr}");
    // The error must list the real spellings, or the user cannot recover.
    assert!(stderr.contains("BrowserCache"), "stderr: {stderr}");
}

#[test]
fn plan_rejects_a_non_numeric_top() {
    let out = Command::new(CLI)
        .args(["plan", "--top", "abc"])
        .output()
        .expect("run cli");
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("--top"));
}

#[test]
fn plan_rejects_a_stray_positional_argument() {
    let out = Command::new(CLI)
        .args(["plan", "somefile.txt"])
        .output()
        .expect("run cli");
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("unexpected argument"));
}
