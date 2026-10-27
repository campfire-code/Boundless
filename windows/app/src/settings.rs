//! 持久化设置，存在 %APPDATA%\Boundless\settings.json

use std::path::{Path, PathBuf};

use boundless_core::geometry::{Point, Rect};
use boundless_core::pairing;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// 共享本机键鼠
    Server,
    /// 被另一台控制
    Client,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub role: Option<Role>,
    /// 主控端的配对码，首次读取时生成
    server_code: Option<String>,
    /// 被控端输入的配对码
    client_code: Option<String>,
    /// 被控端指定连接的主控端；None 表示只发现一台时自动连接
    pub preferred_server: Option<String>,
    pub clipboard_sync: bool,
    /// 屏幕排列：被控端桌面外框左上角在主控端坐标系中的位置；None 表示用默认摆放
    arrangement_origin: Option<[f64; 2]>,
    /// 最近一次收到的被控端屏幕布局，被控端未连接时也能打开排列窗口
    client_displays: Vec<[f64; 4]>,
    /// 最近一次连接的被控端名称
    pub client_name: Option<String>,
    #[serde(skip)]
    path: PathBuf,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            role: None,
            server_code: None,
            client_code: None,
            preferred_server: None,
            clipboard_sync: true,
            arrangement_origin: None,
            client_displays: Vec::new(),
            client_name: None,
            path: PathBuf::new(),
        }
    }
}

impl Settings {
    pub fn load(dir: &Path) -> Settings {
        let path = dir.join("settings.json");
        let mut s: Settings = std::fs::read(&path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        s.path = path;
        s
    }

    pub fn save(&self) {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(data) = serde_json::to_vec_pretty(self) {
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, data).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
            }
        }
    }

    pub fn server_code(&mut self) -> String {
        if let Some(code) = self.server_code.as_deref().and_then(pairing::normalize) {
            return code;
        }
        self.regenerate_server_code()
    }

    pub fn regenerate_server_code(&mut self) -> String {
        let code = pairing::generate_code();
        self.server_code = Some(code.clone());
        self.save();
        code
    }

    pub fn client_code(&self) -> Option<String> {
        self.client_code.as_deref().and_then(pairing::normalize)
    }

    pub fn set_client_code(&mut self, code: Option<String>) {
        self.client_code = code;
        self.save();
    }

    pub fn arrangement_origin(&self) -> Option<Point> {
        self.arrangement_origin.map(|[x, y]| Point::new(x, y))
    }

    pub fn set_arrangement_origin(&mut self, origin: Option<Point>) {
        self.arrangement_origin = origin.map(|p| [p.x, p.y]);
        self.save();
    }

    pub fn client_displays(&self) -> Vec<Rect> {
        self.client_displays.iter().map(|[x, y, w, h]| Rect::new(*x, *y, *w, *h)).collect()
    }

    pub fn set_client_displays(&mut self, displays: &[Rect]) {
        self.client_displays = displays.iter().map(|r| [r.x, r.y, r.w, r.h]).collect();
        self.save();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_defaults() {
        let dir = std::env::temp_dir().join(format!("boundless-settings-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut s = Settings::load(&dir);
        assert!(s.clipboard_sync, "剪贴板同步默认打开");
        assert_eq!(s.role, None);
        let code = s.server_code();
        assert_eq!(s.server_code(), code, "配对码生成一次后保持不变");
        s.role = Some(Role::Client);
        s.set_client_code(Some("abcd efgh jkmn".into()));
        s.set_arrangement_origin(Some(Point::new(1512.0, -20.5)));
        s.set_client_displays(&[Rect::new(0.0, 0.0, 1920.0, 1080.0)]);
        s.save();

        let back = Settings::load(&dir);
        assert_eq!(back.role, Some(Role::Client));
        assert_eq!(back.client_code(), Some("ABCD-EFGH-JKMN".into()), "读出时规范化");
        assert_eq!(back.arrangement_origin(), Some(Point::new(1512.0, -20.5)));
        assert_eq!(back.client_displays(), vec![Rect::new(0.0, 0.0, 1920.0, 1080.0)]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn broken_file_falls_back_to_defaults() {
        let dir = std::env::temp_dir().join(format!("boundless-settings-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("settings.json"), b"{ not json").unwrap();
        let s = Settings::load(&dir);
        assert_eq!(s.role, None);
        assert!(s.clipboard_sync);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
