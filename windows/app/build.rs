fn main() {
    // 图标、DPI 感知清单、版本信息；只在编译 Windows 版时嵌入
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        println!("cargo:rerun-if-changed=res");
        #[cfg(windows)]
        embed();
        #[cfg(not(windows))]
        embed_cross();
    }
}

#[cfg(windows)]
fn embed() {
    embed_resource::compile("res/boundless.rc", embed_resource::NONE).manifest_required().unwrap();
}

/// 在 macOS / Linux 上交叉编译时，构建脚本本身跑在宿主机上，cfg(windows) 不成立，直接调 mingw 的 windres
#[cfg(not(windows))]
fn embed_cross() {
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let obj = out.join("boundless-res.o");
    let status = std::process::Command::new("x86_64-w64-mingw32-windres")
        .args(["--input-format=rc", "--output-format=coff", "-c", "65001", "-I", "res", "-i", "res/boundless.rc", "-o"])
        .arg(&obj)
        .status()
        .expect("找不到 x86_64-w64-mingw32-windres，请先 brew install mingw-w64");
    assert!(status.success(), "windres 编译资源失败");
    println!("cargo:rustc-link-arg-bins={}", obj.display());
}
