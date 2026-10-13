//! # core-engine-cli
//!
//! Development, audit, and operational CLI for KernSifter's core engine.
//!
//! ```text
//! USAGE:
//!     core-engine-cli <SUBCOMMAND> [OPTIONS]
//!
//! SUBCOMMANDS:
//!     audit [--pretty] [--strict] <path> [path...]
//!         Validate paths against the protected-path matrix (host platform)
//!         and print verdicts as JSON. Default subcommand when none is given.
//!
//!     scan [-o <file>] [--no-walk]
//!         Run a platform scan (all sanctioned roots) and print a summary.
//!         With -o, also write the full dry-run manifest JSON to <file>.
//!         With --no-walk, only list the discovered scan roots without
//!         walking them (fast audit of what would be scanned).
//!
//!     plan [-o <file>] [--category <Cat>]... [--include-recent] [--json]
//!          [--top <n>]
//!         Run a scan and show the executor's verdicts without touching
//!         anything: what may be cleaned, what was declined, and why.
//!         With -o, freeze the eligible set into a manifest you can execute.
//!
//!     manifest <file> [--verify]
//!         Load a manifest from a JSON file, verify structural truthfulness,
//!         and print a summary. With --verify, only checks the file (exit 0
//!         if valid, 1 with error message if invalid).
//!
//!     empty-trash
//!         Permanently empty the current user's OS recycle bin (requires
//!         typing the confirmation phrase — irreversible).
//!
//!     trash-summary
//!         Print a read-only breakdown of the recycle bin contents (totals,
//!         per file type, largest files) before deciding whether to empty it.
//!
//!     -h, --help   Show this help.
//! ```

use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use core_engine::{
    scan, platform_roots, DryRunManifest, ManifestRegistry, execute_manifest,
    ExecutionStatus, validate_path, Category, PlanOptions, empty_recycle_bin,
    recycle_bin_summary, plan as compute_plan,
};

const USAGE: &str = r"KernSifter — cross-platform space audit & cleaning engine.

USAGE:
    core-engine-cli <SUBCOMMAND> [OPTIONS]

SUBCOMMANDS:
    audit [--pretty] [--strict] <path> [path...]
        Validate paths against the protected-path matrix and print verdicts.

    scan [-o <file>] [--no-walk]
        Run a platform scan. With -o <file>, write the dry-run manifest JSON.
        With --no-walk, only list discovered scan roots without walking them.

    plan [-o <file>] [--category <Cat>]... [--include-recent] [--json] [--top <n>]
        Show the executor's verdicts on a fresh scan: what is eligible to
        clean, what was declined and why. Nothing is changed.
        --category <Cat>  Select a category explicitly (repeatable). Without
                          any, this is a smart clean over routine categories.
        --include-recent  Ignore the per-category age floors.
        --json            Print the full plan as JSON.
        --top <n>         Show the n largest eligible entries (default 20).
        -o <file>         Freeze the eligible set into a manifest JSON, ready
                          for `execute <file>`.

    manifest <file> [--verify]
        Load a manifest from JSON, verify it, and print a summary.

    execute <file> [--simulate] [--no-simulate]
        Execute a manifest: move cleanable files to the OS trash.
        --simulate (default): simulate only, nothing is changed.
        --no-simulate: actually move files to the recycle bin.
        Requires explicit confirmation prompt.

    empty-trash
        Permanently empty the current user's OS recycle bin.
        Requires typing the confirmation phrase. This is the one
        irreversible operation KernSifter offers — nothing is recoverable.

    trash-summary
        Print a read-only breakdown of the recycle bin contents (totals,
        per file type, largest files) before deciding whether to empty it.

    -h, --help   Show this help.
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.is_empty() {
        eprintln!("error: no paths given\n\n{USAGE}");
        return ExitCode::from(2);
    }

    match args[0].as_str() {
        "-h" | "--help" => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        "audit" => cmd_audit(&args[1..]),
        "scan" => cmd_scan(&args[1..]),
        "plan" => cmd_plan(&args[1..]),
        "manifest" => cmd_manifest(&args[1..]),
        "execute" => cmd_execute(&args[1..]),
        "empty-trash" => cmd_empty_trash(&args[1..]),
        "trash-summary" => cmd_trash_summary(&args[1..]),
        "bench" => cmd_bench(&args[1..]),
        // Backward-compat and convenience: treat anything else as an audit path.
        _ => cmd_audit(&args),
    }
}

// ── audit ─────────────────────────────────────────────────────────────────

fn cmd_audit(args: &[String]) -> ExitCode {
    let mut pretty = false;
    let mut strict = false;
    let mut paths: Vec<PathBuf> = Vec::new();
    let mut after_dd = false;

    for a in args {
        if after_dd { paths.push(PathBuf::from(a)); continue; }
        match a.as_str() {
            "--" => after_dd = true,
            "--pretty" => pretty = true,
            "--strict" => strict = true,
            s if s.starts_with('-') => {
                eprintln!("unknown option: {s}\n\n{USAGE}");
                return ExitCode::from(2);
            }
            _ => paths.push(PathBuf::from(a)),
        }
    }

    if paths.is_empty() {
        eprintln!("error: no paths given\n\n{USAGE}");
        return ExitCode::from(2);
    }

    let lines: Vec<serde_json::Value> = paths.iter().map(|p| {
        let v = validate_path(p);
        serde_json::json!({
            "path": p.display().to_string(),
            "allowed": v.allowed,
            "reason": v.reason,
            "rule": v.rule,
        })
    }).collect();

    if pretty {
        println!("{}", serde_json::to_string_pretty(&lines).unwrap());
    } else {
        for line in &lines {
            println!("{}", serde_json::to_string(line).unwrap());
        }
    }

    if strict && lines.iter().any(|l| l.get("allowed") == Some(&serde_json::Value::Bool(false))) {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

// ── bench (deprecated alias for audit) ────────────────────────────────────

#[allow(dead_code)]
fn cmd_bench(args: &[String]) -> ExitCode {
    cmd_audit(args)
}

// ── scan ──────────────────────────────────────────────────────────────────

fn cmd_scan(args: &[String]) -> ExitCode {
    let mut out_file: Option<String> = None;
    let mut no_walk = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-o" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: -o requires a file path");
                    return ExitCode::from(2);
                }
                out_file = Some(args[i].clone());
            }
            "--no-walk" => no_walk = true,
            s if s.starts_with('-') => {
                eprintln!("unknown option: {s}\n\n{USAGE}");
                return ExitCode::from(2);
            }
            _ => {
                eprintln!("unexpected argument: {}\n\n{USAGE}", args[i]);
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let roots = platform_roots();

    if no_walk {
        println!("=== Discovered scan roots (--no-walk) ===\n");
        let mut by_cat: Vec<(&str, Vec<&PathBuf>)> = Vec::new();
        for r in &roots {
            let cat_name = category_label(r.category);
            if let Some((_, v)) = by_cat.iter_mut().find(|(c, _)| *c == cat_name) {
                v.push(&r.path);
            } else {
                by_cat.push((cat_name, vec![&r.path]));
            }
        }
        // Sort categories for stable output.
        by_cat.sort_by_key(|(c, _)| *c);
        for (cat, paths) in &by_cat {
            println!("  [{cat}]  ({count} roots)", count = paths.len());
            for p in paths {
                let exists = if p.is_dir() { "" } else { "  (not present)" };
                println!("    {}{}", p.display(), exists);
            }
            println!();
        }
        println!("Total: {} roots across {} categories", roots.len(), by_cat.len());
        println!("(omit --no-walk to run the full parallel scan)");
        return ExitCode::SUCCESS;
    }

    // ── Real scan ──
    eprintln!("Scanning platform roots ({} discovered)…", roots.len());
    let start = Instant::now();
    let report = scan();
    let elapsed = start.elapsed();

    let total = report.total_bytes();
    let cleanable = report.cleanable_bytes();
    let counts = report.entry_count();

    println!("╔══════════════════════════════════════════════╗");
    println!("║          KERNSIFTER — SCAN REPORT           ║");
    println!("╠══════════════════════════════════════════════╣");
    println!("║  {:>8} entries scanned                   ║", counts);
    println!("║  {:>8} total                             ║", fmt_bytes(total));
    println!("║  {:>8} cleanable                        ║", fmt_bytes(cleanable));
    let blocked = report.roots.iter()
        .flat_map(|r| r.entries.iter())
        .filter(|e| !e.is_cleanable())
        .count();
    println!("║  {:>8} blocked (not cleanable)         ║", blocked);
    println!("║  {:>8} scan time                        ║", format!("{:.1}s", elapsed.as_secs_f64()));
    println!("╠══════════════════════════════════════════════╣");

    let by_cat = report.bytes_by_category();
    let mut cats: Vec<_> = by_cat.iter().collect();
    cats.sort_by(|a, b| b.1.cmp(a.1));
    for (cat, &bytes) in &cats {
        let label = category_label(**cat);
        let pct = if total > 0 { 100.0 * bytes as f64 / total as f64 } else { 0.0 };
        println!("║  {:>6}  {:<34} ║", fmt_bytes(bytes), format!("{} ({pct:.0}%)", label));
    }
    println!("╚══════════════════════════════════════════════╝");

    // Errors
    for root in &report.roots {
        for err in &root.errors {
            eprintln!("  [!] {}: {}", root.root.path.display(), err);
        }
    }

    // Manifest output
    if let Some(path) = &out_file {
        eprintln!("\nWriting manifest to {path}…");
        let registry = ManifestRegistry::default();
        let id = registry.register(&report);
        let manifest = registry.get(id).expect("just registered");
        match manifest.to_file(path) {
            Ok(()) => {
                eprintln!("Manifest #{} written ({} entries, {} cleanable).",
                    manifest.id, manifest.entries.len(), fmt_bytes(manifest.cleanable_bytes));
                eprintln!("Review the file, then execute with: core-engine-cli manifest \"{}\" --verify", path);
            }
            Err(e) => {
                eprintln!("Failed to write manifest: {e}");
                return ExitCode::from(1);
            }
        }
    } else {
        println!("\n(use -o <file> to write the full dry-run manifest as JSON)");
    }

    ExitCode::SUCCESS
}

// ── plan ──────────────────────────────────────────────────────────────────

/// Parses a `Category` from the CLI's canonical spelling. Shared by `plan` and
/// `execute` so the two can never disagree about what a category name means.
fn parse_category(s: &str) -> Result<Category, String> {
    Ok(match s {
        "Temp" => Category::Temp,
        "Cache" => Category::Cache,
        "Logs" => Category::Logs,
        "PackageCache" => Category::PackageCache,
        "Prefetch" => Category::Prefetch,
        "BrowserCache" => Category::BrowserCache,
        "SiteStorage" => Category::SiteStorage,
        "AppOrphan" => Category::AppOrphan,
        "AiModels" => Category::AiModels,
        "RecycleBin" => Category::RecycleBin,
        other => return Err(format!("unknown category: {other}")),
    })
}

const CATEGORY_NAMES: &str = "Temp, Cache, Logs, PackageCache, Prefetch, BrowserCache, SiteStorage, AppOrphan, AiModels, RecycleBin";

fn cmd_plan(args: &[String]) -> ExitCode {
    let mut out_file: Option<String> = None;
    let mut include_recent = false;
    let mut as_json = false;
    let mut top: usize = 20;
    let mut selected: Vec<Category> = Vec::new();
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "-o" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: -o requires a file path");
                    return ExitCode::from(2);
                }
                out_file = Some(args[i].clone());
            }
            "--category" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --category requires a value ({CATEGORY_NAMES})");
                    return ExitCode::from(2);
                }
                match parse_category(args[i].as_str()) {
                    Ok(c) => selected.push(c),
                    Err(e) => {
                        eprintln!("error: {e} ({CATEGORY_NAMES})");
                        return ExitCode::from(2);
                    }
                }
            }
            "--include-recent" => include_recent = true,
            "--json" => as_json = true,
            "--top" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --top requires a number");
                    return ExitCode::from(2);
                }
                match args[i].parse::<usize>() {
                    Ok(n) => top = n,
                    Err(_) => {
                        eprintln!("error: --top expects a number, got: {}", args[i]);
                        return ExitCode::from(2);
                    }
                }
            }
            s if s.starts_with('-') => {
                eprintln!("unknown option: {s}\n\n{USAGE}");
                return ExitCode::from(2);
            }
            other => {
                eprintln!("unexpected argument: {other}\n\n{USAGE}");
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    eprintln!("Scanning platform roots…");
    let start = Instant::now();
    let report = scan();
    let scanned_in = start.elapsed().as_secs_f64();

    let mut options = if selected.is_empty() {
        PlanOptions::smart_clean(now)
    } else {
        PlanOptions::selecting(now, selected.clone())
    };
    if include_recent {
        options = options.including_recent();
    }

    let cleanup = compute_plan(&report, &options);

    if as_json {
        let value = serde_json::to_value(&cleanup);
        match value {
            Ok(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap()),
            Err(e) => {
                eprintln!("failed to serialize plan: {e}");
                return ExitCode::from(1);
            }
        }
    } else {
        print_plan_summary(&cleanup, top);
    }

    eprintln!(
        "\n(scanned in {:.1}s; nothing was modified)",
        scanned_in
    );

    if let Some(path) = &out_file {
        // Freeze exactly the eligible set: the manifest engine consumes
        // reports, and `to_scan_report` is the seam that keeps the Phase 2
        // gates untouched. Execution re-validates every entry regardless.
        let registry = ManifestRegistry::default();
        let id = registry.register(&cleanup.to_scan_report());
        let manifest = registry.get(id).expect("just registered");
        match manifest.to_file(path) {
            Ok(()) => {
                eprintln!(
                    "Manifest #{} written: {} entries, {} eligible ({}).",
                    manifest.id,
                    manifest.entries.len(),
                    cleanup.eligible_count(),
                    fmt_bytes(cleanup.eligible_bytes())
                );
                eprintln!("Review it, then run: core-engine-cli execute \"{path}\"");
            }
            Err(e) => {
                eprintln!("Failed to write manifest: {e}");
                return ExitCode::from(1);
            }
        }
    } else {
        eprintln!("(use -o <file> to freeze this plan into an executable manifest)");
    }

    ExitCode::SUCCESS
}

fn print_plan_summary(cleanup: &core_engine::CleanupPlan, top: usize) {
    let eligible = cleanup.eligible_count();
    let eligible_bytes = cleanup.eligible_bytes();
    let total_bytes = eligible_bytes
        + cleanup
            .skipped
            .iter()
            .map(|s| s.size_bytes)
            .sum::<u64>();

    println!();
    println!("╔══════════════════════════════════════════════╗");
    println!("║        KERNSIFTER — CLEANUP PLAN             ║");
    println!("╠══════════════════════════════════════════════╣");
    println!(
        "║  {:>8} eligible to clean                ║",
        fmt_bytes(eligible_bytes)
    );
    println!(
        "║  {:>8} declined, with reasons           ║",
        cleanup.skipped_count()
    );
    println!(
        "║  {:>8} candidates considered            ║",
        eligible + cleanup.skipped_count()
    );
    println!(
        "║  {:>8} of {} accounted for          ║",
        fmt_bytes(total_bytes),
        fmt_bytes(total_bytes)
    );
    if cleanup.needs_elevation {
        println!("║  some eligible paths need elevation     ║");
    }
    println!("╚══════════════════════════════════════════════╝");

    // What the eligible set is actually made of. `plan` defaults to a smart
    // clean over routine categories, so this is the quickest answer to "what
    // am I about to clean?" — and the clearest way to see that an
    // explicitly-ticked category dominates the total.
    if eligible > 0 {
        let mut by_cat: Vec<(Category, usize, u64)> = Vec::new();
        for entry in &cleanup.eligible {
            match by_cat.iter_mut().find(|(c, _, _)| *c == entry.category) {
                Some((_, count, bytes)) => {
                    *count += 1;
                    *bytes += entry.size_bytes;
                }
                None => by_cat.push((entry.category, 1, entry.size_bytes)),
            }
        }
        by_cat.sort_by(|a, b| b.2.cmp(&a.2));
        println!();
        println!("  Eligible by category:");
        for (category, count, bytes) in &by_cat {
            let pct = if eligible_bytes > 0 {
                100.0 * *bytes as f64 / eligible_bytes as f64
            } else {
                0.0
            };
            println!(
                "    {:>8}  {:>6}  {:<16}  {:.0}%",
                fmt_bytes(*bytes),
                count,
                category_label(*category),
                pct
            );
        }
    }

    // Why things were declined — the "why is this still here?" panel.
    let by_reason = cleanup.skipped_bytes_by_reason();
    if !by_reason.is_empty() {
        println!();
        println!("  Declined, by reason:");
        let max = by_reason.iter().map(|(_, b)| *b).max().unwrap_or(0).max(1);
        for (reason, bytes) in &by_reason {
            let count = cleanup.skipped.iter().filter(|s| &s.reason == reason).count();
            let filled = ((40 * bytes / max) as usize).max(1);
            let flag = if reason.is_permanent() {
                "permanent"
            } else {
                "age"
            };
            println!(
                "    {:>8}  {:>4}  {:<8}  {}  {}",
                fmt_bytes(*bytes),
                count,
                flag,
                "█".repeat(filled),
                reason.message()
            );
        }
    }

    // Largest eligible entries — what the user would actually get back.
    if eligible > 0 {
        let mut largest: Vec<&core_engine::ScanEntry> = cleanup.eligible.iter().collect();
        largest.sort_by(|a, b| b.size_bytes.cmp(&a.size_bytes));
        let n = top.min(largest.len());
        println!();
        println!("  Largest eligible entries ({} of {}):", n, eligible);
        for entry in largest.iter().take(n) {
            println!(
                "    {:>8}  [{:<14}]  {}",
                fmt_bytes(entry.size_bytes),
                category_label(entry.category),
                entry.path.display()
            );
        }
        if n < eligible {
            println!("    … and {} more (use --top to see more)", eligible - n);
        }
    }
}

// ── manifest ──────────────────────────────────────────────────────────────

fn cmd_manifest(args: &[String]) -> ExitCode {
    let mut verify_only = false;
    let mut file: Option<String> = None;

    for a in args {
        match a.as_str() {
            "--verify" => verify_only = true,
            s if s.starts_with('-') => {
                eprintln!("unknown option: {s}\n\n{USAGE}");
                return ExitCode::from(2);
            }
            _ if file.is_none() => file = Some(a.clone()),
            _ => {
                eprintln!("unexpected argument: {a}\n\n{USAGE}");
                return ExitCode::from(2);
            }
        }
    }

    let path = match file {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!("error: manifest file path required\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };

    // Check the file exists and is readable before we try to parse.
    if !path.exists() {
        eprintln!("file not found: {}", path.display());
        return ExitCode::from(1);
    }

    let json = match fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("cannot read {}: {e}", path.display());
            return ExitCode::from(1);
        }
    };

    let manifest = match DryRunManifest::from_json(&json) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("invalid manifest JSON: {e}");
            return ExitCode::from(1);
        }
    };

    if verify_only {
        match manifest.verify() {
            Ok(()) => {
                println!("✓ Manifest #{} is structurally valid.", manifest.id);
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("✗ Manifest #{} verification failed: {e}", manifest.id);
                ExitCode::from(1)
            }
        }
    } else {
        // Print summary
        println!("╔══════════════════════════════════════════════╗");
        println!("║       KERNSIFTER — MANIFEST REVIEW          ║");
        println!("╠══════════════════════════════════════════════╣");
        println!("║  Manifest #{:<36} ║", manifest.id);
        println!("║  Version: {:<35} ║", manifest.version);
        println!("║  {:>8} entries                          ║", manifest.entries.len());
        println!("║  {:>8} total                            ║", fmt_bytes(manifest.total_bytes));
        println!("║  {:>8} cleanable                       ║", fmt_bytes(manifest.cleanable_bytes));
        println!("║  {:>8} blocked                         ║", manifest.blocked_count);
        println!("╠══════════════════════════════════════════════╣");

        // Verify structural truthfulness.
        match manifest.verify() {
            Ok(()) => println!("║  ✓  Structural verification passed           ║"),
            Err(e) => println!("║  ✗  Verification FAILED: {:<22} ║", e),
        }

        println!("╚══════════════════════════════════════════════╝");

        // Top 10 largest cleanable entries.
        println!("\nTop cleanable entries by size:");
        let mut cleanable: Vec<_> = manifest.entries.iter()
            .filter(|e| e.verdict.allowed)
            .collect();
        cleanable.sort_by_key(|e| std::cmp::Reverse(e.size_bytes));
        for (i, e) in cleanable.iter().take(15).enumerate() {
            println!("  {:>3}. {:>8}  {}",
                i + 1,
                fmt_bytes(e.size_bytes),
                e.path.display());
        }
        if cleanable.len() > 15 {
            println!("  … and {} more cleanable entries.", cleanable.len() - 15);
        }

        ExitCode::SUCCESS
    }
}

// ── execute ───────────────────────────────────────────────────────────────

fn cmd_execute(args: &[String]) -> ExitCode {
    let mut simulate = true;
    let mut file: Option<String> = None;
    let mut exclude_categories: Vec<Category> = Vec::new();
    let mut exclude_prefixes: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--simulate" => simulate = true,
            "--no-simulate" => simulate = false,
            "--exclude-category" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --exclude-category requires a value ({CATEGORY_NAMES})");
                    return ExitCode::from(2);
                }
                match parse_category(args[i].as_str()) {
                    Ok(c) => exclude_categories.push(c),
                    Err(e) => {
                        eprintln!("error: {e} ({CATEGORY_NAMES})");
                        return ExitCode::from(2);
                    }
                }
            }
            "--exclude-path-prefix" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --exclude-path-prefix requires a value");
                    return ExitCode::from(2);
                }
                exclude_prefixes.push(args[i].clone());
            }
            s if s.starts_with('-') => {
                eprintln!("unknown option: {s}\n\n{USAGE}");
                return ExitCode::from(2);
            }
            _ if file.is_none() => file = Some(args[i].clone()),
            _ => {
                eprintln!("unexpected argument: {}\n\n{USAGE}", args[i]);
                return ExitCode::from(2);
            }
        }
        i += 1;
    }

    let path = match file {
        Some(p) => PathBuf::from(p),
        None => {
            eprintln!("error: manifest file path required\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };

    if !path.exists() {
        eprintln!("file not found: {}", path.display());
        return ExitCode::from(1);
    }

    let json = match fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("cannot read {}: {e}", path.display());
            return ExitCode::from(1);
        }
    };

    let mut manifest = match DryRunManifest::from_json(&json) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("invalid manifest JSON: {e}");
            return ExitCode::from(1);
        }
    };

    // Apply category and path-prefix exclusions.
    let before = manifest.entries.len();
    let before_bytes = manifest.total_bytes;
    if !exclude_categories.is_empty() {
        manifest.entries.retain(|e| !exclude_categories.contains(&e.category));
    }
    if !exclude_prefixes.is_empty() {
        manifest.entries.retain(|e| {
            let p = e.path.to_string_lossy();
            !exclude_prefixes.iter().any(|prefix| p.starts_with(prefix))
        });
    }
    let removed = before - manifest.entries.len();
    if removed > 0 {
        manifest.total_bytes = manifest.entries.iter().map(|e| e.size_bytes).sum();
        manifest.cleanable_bytes = manifest.entries.iter()
            .filter(|e| e.verdict.allowed).map(|e| e.size_bytes).sum();
        manifest.blocked_count = manifest.entries.iter()
            .filter(|e| !e.verdict.allowed).count();
        eprintln!("Filtered: {} entries excluded ({} saved).",
            removed, fmt_bytes(before_bytes.saturating_sub(manifest.total_bytes)));
        for cat in &exclude_categories {
            eprintln!("  --exclude-category {}", category_label(*cat));
        }
        for pfx in &exclude_prefixes {
            eprintln!("  --exclude-path-prefix {}", pfx);
        }
        eprintln!();
    }

    // Verify the manifest is structurally truthful before doing anything.
    if let Err(e) = manifest.verify() {
        eprintln!("manifest verification failed — refusing to execute: {e}");
        return ExitCode::from(1);
    }

    // Re-discover platform roots to register deep-scan carve-outs in the
    // protection matrix. The manifest was loaded from a file (might be from a
    // prior process), so the matrix hasn't been primed yet.
    let _ = platform_roots();

    let registry = ManifestRegistry::default();
    registry.register_manifest(manifest.clone());

    if simulate {
        eprintln!("SIMULATION MODE — nothing will be moved or deleted.");
        eprintln!("Manifest #{}: {} entries, {} cleanable, {} blocked.",
            manifest.id, manifest.entries.len(),
            fmt_bytes(manifest.cleanable_bytes), manifest.blocked_count);
        eprintln!("");
    } else {
        eprintln!("⚠  THIS WILL MOVE {} WORTH OF FILES TO THE RECYCLE BIN (recoverable).",
            fmt_bytes(manifest.cleanable_bytes));
        eprint!("Type 'yes' to confirm: ");
        let mut input = String::new();
        if std::io::stdin().read_line(&mut input).is_err() || input.trim() != "yes" {
            eprintln!("Aborted.");
            return ExitCode::from(0);
        }
    }

    match execute_manifest(&registry, manifest.id, true, simulate) {
        Ok(report) => {
            println!();
            println!("╔══════════════════════════════════════════════╗");
            println!("║       KERNSIFTER — EXECUTION RESULT         ║");
            println!("╠══════════════════════════════════════════════╣");
            if simulate {
                println!("║  SIMULATION — nothing was changed            ║");
                println!("║  {:>8} would be moved to trash          ║", fmt_bytes(report.simulated_bytes));
            } else {
                println!("║  {:>8} moved to Recycle Bin              ║", fmt_bytes(report.trashed_bytes));
            }
            let moved = report.outcomes.iter().filter(|o| o.status == ExecutionStatus::Trashed).count();
            let sim = report.outcomes.iter().filter(|o| o.status == ExecutionStatus::Simulated).count();
            let blocked = report.outcomes.iter().filter(|o| o.status == ExecutionStatus::Blocked).count();
            let missing = report.outcomes.iter().filter(|o| o.status == ExecutionStatus::Missing).count();
            let failed = report.outcomes.iter().filter(|o| o.status == ExecutionStatus::Failed).count();
            println!("║  {:>8} trashed / simulated               ║", moved + sim);
            println!("║  {:>8} blocked (re-validated)            ║", blocked);
            println!("║  {:>8} missing (since scan)              ║", missing);
            println!("║  {:>8} failed                            ║", failed);
            println!("╚══════════════════════════════════════════════╝");

            if failed > 0 || blocked > 0 {
                println!();
                for outcome in &report.outcomes {
                    if outcome.status == ExecutionStatus::Blocked
                        || outcome.status == ExecutionStatus::Failed
                    {
                        println!("  {:>10}  {}",
                            format!("{:?}", outcome.status).to_lowercase(),
                            outcome.path.display());
                        if let Some(detail) = &outcome.detail {
                            println!("            {detail}");
                        }
                    }
                }
            }

            if simulate {
                println!("\n⚠  Simulation complete. Run with --no-simulate to actually clean.");
                println!("   Staging moves files to the Recycle Bin, which frees no disk space");
                println!("   until the bin is emptied (empty-trash, permanent).");
            } else {
                println!("\n✓  Files are in the Recycle Bin — recoverable from the desktop.");
                println!("   Note: the Recycle Bin still occupies that space. Reclaim it with");
                println!("   `core-engine-cli empty-trash` — which is permanent.");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("Execution refused: {e}");
            ExitCode::from(1)
        }
    }
}

// ── empty-trash ───────────────────────────────────────────────────────────

fn cmd_empty_trash(args: &[String]) -> ExitCode {
    for a in args {
        if a == "-h" || a == "--help" {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        eprintln!("unknown option: {a}\n\n{USAGE}");
        return ExitCode::from(2);
    }

    eprintln!("⚠  THIS PERMANENTLY EMPTIES YOUR OS RECYCLE BIN.");
    eprintln!("   Files in the trash are deleted forever — they cannot be recovered.");
    eprint!("Type 'EMPTY' to confirm: ");
    let mut input = String::new();
    if std::io::stdin().read_line(&mut input).is_err() || input.trim() != "EMPTY" {
        eprintln!("Aborted.");
        return ExitCode::from(0);
    }

    match empty_recycle_bin(true) {
        Ok(report) => {
            println!();
            println!("╔══════════════════════════════════════════════╗");
            println!("║        KERNSIFTER — EMPTY TRASH RESULT       ║");
            println!("╠══════════════════════════════════════════════╣");
            println!("║  {:>8} entries removed                  ║", report.removed_entries);
            println!("║  {:>8} removed                        ║", fmt_bytes(report.removed_bytes));
            println!("╚══════════════════════════════════════════════╝");
            for err in &report.errors {
                eprintln!("  [!] {err}");
            }
            if report.errors.is_empty() {
                println!("\n✓  Recycle bin emptied.");
            } else {
                println!("\n✓  Recycle bin emptied (with {} non-fatal issues).", report.errors.len());
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("Empty refused: {e}");
            ExitCode::from(1)
        }
    }
}

// ── trash-summary ─────────────────────────────────────────────────────────

fn cmd_trash_summary(args: &[String]) -> ExitCode {
    for a in args {
        if a == "-h" || a == "--help" {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        eprintln!("unknown option: {a}\n\n{USAGE}");
        return ExitCode::from(2);
    }

    let s = recycle_bin_summary();

    println!("╔══════════════════════════════════════════════╗");
    println!("║     KERNSIFTER — RECYCLE BIN SUMMARY        ║");
    println!("╠══════════════════════════════════════════════╣");
    println!("║  {:>8} entries in trash                 ║", s.total_entries);
    println!("║  {:>8} in trash                       ║", fmt_bytes(s.total_bytes));
    println!("╚══════════════════════════════════════════════╝");

    if s.total_entries == 0 {
        println!("\nRecycle bin is empty (nothing readable by this user).");
        return ExitCode::SUCCESS;
    }

    println!("\nBy file type:");
    for g in &s.by_extension {
        println!("  {:>8}  {:>6} files  .{}", fmt_bytes(g.bytes), g.entries, g.extension);
    }

    println!("\nLargest files:");
    for (i, f) in s.largest_files.iter().enumerate() {
        println!("  {:>3}. {:>8}  {}", i + 1, fmt_bytes(f.size_bytes), f.path.display());
    }

    println!("\n(read-only — empty with: core-engine-cli empty-trash)");
    ExitCode::SUCCESS
}

// ── helpers ───────────────────────────────────────────────────────────────

fn fmt_bytes(n: u64) -> String {
    const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 { format!("{n} B") }
    else { format!("{v:.1} {}", UNITS[i]) }
}

fn category_label(c: Category) -> &'static str {
    match c {
        Category::Temp => "Temp",
        Category::Cache => "Cache",
        Category::Logs => "Logs",
        Category::PackageCache => "Package cache",
        Category::Prefetch => "Prefetch",
        Category::BrowserCache => "Browser cache",
        Category::SiteStorage => "Site storage",
        Category::AppOrphan => "AppData orphan",
        Category::AiModels => "AI models",
        Category::RecycleBin => "Recycle bin",
    }
}