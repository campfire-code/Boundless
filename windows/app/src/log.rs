//! 简单的文件日志：%APPDATA%\Boundless\boundless.log，超过 1MB 时从头写。出问题时让用户把这个文件发过来

use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static FILE: Mutex<Option<PathBuf>> = Mutex::new(None);

pub fn init(dir: &std::path::Path) {
    let _ = std::fs::create_dir_all(dir);
    let path = dir.join("boundless.log");
    if std::fs::metadata(&path).map(|m| m.len() > 1 << 20).unwrap_or(false) {
        let _ = std::fs::remove_file(&path);
    }
    *FILE.lock().unwrap() = Some(path);
}

pub fn write(msg: &str) {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let line = format!("[{secs:.3}] {msg}\n");
    if cfg!(debug_assertions) {
        eprint!("{line}");
    }
    let Some(path) = FILE.lock().unwrap().clone() else { return };
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = f.write_all(line.as_bytes());
    }
}

#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => { $crate::log::write(&format!($($arg)*)) };
}
