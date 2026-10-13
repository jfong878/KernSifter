fn main() {
    // GNU ld on windows-gnu overflows the 16-bit PE ordinal table while linking
    // webview2-com's ~100k COM symbols ("export ordinal too large"); --kill-at
    // switches those exports to name-based, which the PE format can hold.
    //
    // Scoped to this package on purpose: as a workspace-wide rustflag it also
    // rewrites proc-macro DLL imports and breaks every proc-macro link.
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("gnu") {
        println!("cargo:rustc-link-arg=-Wl,--kill-at");
    }
    tauri_build::build()
}
