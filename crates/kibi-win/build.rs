//! Kibi's icon and version in kibi-win.exe. The icon is for Explorer, Start
//! and a pinned taskbar button (the running window sets its own). The
//! version is for Explorer's Details and for Windows Installer, which
//! replaces a file by comparing versions: a file with none it judges by
//! its dates, and keeps one that looks hand-written, so an upgrade could
//! leave an old kibi-win.exe behind. Windows builds only.

use std::path::Path;

// The Kibi Share build key, as crates/kibi/build.rs compiles it: kibi-win
// carries share.rs too, for the window's Share.
include!("../kibi/build_share_key.rs");

fn main() {
    println!("cargo:rerun-if-changed=../kibi/build_share_key.rs");
    write_share_build_key();
    // The bundle files' SHA-256s, set by `cargo xtask windows`.
    println!("cargo:rerun-if-env-changed=KIBI_BUNDLE_SHA256");
    println!("cargo:rerun-if-env-changed=CARGO_PKG_VERSION");
    println!("cargo:rerun-if-changed=../../brand/icon/windows/kibi.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let ico = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../brand/icon/windows/kibi.ico").canonicalize().expect("brand/icon/windows/kibi.ico");
    // The resource compiler takes forward slashes and no \\?\ prefix.
    let ico = ico.to_string_lossy().trim_start_matches(r"\\?\").replace('\\', "/");
    let version = std::env::var("CARGO_PKG_VERSION").expect("CARGO_PKG_VERSION");
    let commas = {
        let mut parts: Vec<String> = version.split(['.', '-', '+']).take(3).map(|p| p.chars().take_while(char::is_ascii_digit).collect()).collect();
        parts.resize(4, "0".to_owned());
        parts.join(",")
    };
    let rc = format!(
        r#"1 ICON "{ico}"
1 VERSIONINFO
FILEVERSION {commas}
PRODUCTVERSION {commas}
FILEOS 0x40004
FILETYPE 0x1
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "Kibi"
      VALUE "FileDescription", "Kibi"
      VALUE "FileVersion", "{version}"
      VALUE "InternalName", "kibi-win"
      VALUE "OriginalFilename", "kibi-win.exe"
      VALUE "ProductName", "Kibi"
      VALUE "ProductVersion", "{version}"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#
    );
    let out = Path::new(&std::env::var("OUT_DIR").expect("OUT_DIR")).join("kibi-win.rc");
    std::fs::write(&out, rc).expect("write kibi-win.rc");
    embed_resource::compile(&out, embed_resource::NONE).manifest_optional().expect("kibi-win.rc");
}
