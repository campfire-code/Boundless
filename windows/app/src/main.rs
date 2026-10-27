//! 无界 Windows 版：托盘程序，可当主控端（共享本机键鼠）或被控端（被另一台控制），与 Mac 版互通

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod log;
mod settings;

#[cfg(windows)]
mod app;
#[cfg(windows)]
mod client;
#[cfg(windows)]
mod server;
#[cfg(windows)]
mod ui;
#[cfg(windows)]
mod win;

#[cfg(windows)]
fn main() {
    app::run();
}

#[cfg(not(windows))]
fn main() {
    eprintln!("无界 Windows 版只能在 Windows 上运行；在 macOS 上请用仓库根目录的 Swift 版。");
    std::process::exit(1);
}
