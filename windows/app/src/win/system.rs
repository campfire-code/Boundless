//! 系统杂项：计算机名、光标、滚轮设置、隐藏光标、开机自启、管理员权限、单实例、网卡类型

use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::ptr::{null, null_mut};

use boundless_core::geometry::Point;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::NetworkManagement::IpHelper::*;
use windows_sys::Win32::Networking::WinSock::{AF_INET, AF_UNSPEC, SOCKADDR_IN};
use windows_sys::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows_sys::Win32::System::LibraryLoader::{GetModuleFileNameW, GetModuleHandleW};
use windows_sys::Win32::System::Registry::*;
use windows_sys::Win32::System::SystemInformation::{ComputerNamePhysicalDnsHostname, GetComputerNameExW};
use windows_sys::Win32::System::Threading::{CreateMutexW, GetCurrentProcess, OpenProcessToken};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::GetDoubleClickTime;
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use super::{from_wide, wide};

pub fn data_dir() -> PathBuf {
    std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir).join("Boundless")
}

pub fn computer_name() -> String {
    let mut buf = [0u16; 256];
    let mut len = buf.len() as u32;
    let ok = unsafe { GetComputerNameExW(ComputerNamePhysicalDnsHostname, buf.as_mut_ptr(), &mut len) };
    if ok != 0 && len > 0 {
        from_wide(&buf)
    } else {
        "Windows".into()
    }
}

pub fn cursor_pos() -> Point {
    let mut p = POINT { x: 0, y: 0 };
    unsafe { GetCursorPos(&mut p) };
    Point::new(p.x as f64, p.y as f64)
}

pub fn set_cursor_pos(p: Point) {
    unsafe { SetCursorPos(p.x.round() as i32, p.y.round() as i32) };
}

/// 「一次滚动的行数」设置
pub fn wheel_lines() -> u32 {
    let mut lines = 3u32;
    unsafe { SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &mut lines as *mut u32 as _, 0) };
    lines
}

/// (双击间隔毫秒, 双击允许的位移像素)
pub fn double_click_metrics() -> (u32, i32, i32) {
    unsafe { (GetDoubleClickTime(), GetSystemMetrics(SM_CXDOUBLECLK), GetSystemMetrics(SM_CYDOUBLECLK)) }
}

/// 进入远程模式时把所有系统光标换成透明的。Windows 没有全局隐藏光标的接口，只能这样
pub fn hide_cursors() {
    const IDS: [u32; 13] = [
        OCR_NORMAL, OCR_IBEAM, OCR_WAIT, OCR_CROSS, OCR_UP, OCR_SIZENWSE, OCR_SIZENESW, OCR_SIZEWE, OCR_SIZENS, OCR_SIZEALL,
        OCR_NO, OCR_HAND, OCR_APPSTARTING,
    ];
    let and_mask = [0xFFu8; 128];
    let xor_mask = [0u8; 128];
    unsafe {
        let hinst = GetModuleHandleW(null());
        for id in IDS {
            // SetSystemCursor 会接管并销毁传入的光标，每个都要新建一个
            let cursor = CreateCursor(hinst, 0, 0, 32, 32, and_mask.as_ptr() as _, xor_mask.as_ptr() as _);
            if !cursor.is_null() {
                SetSystemCursor(cursor, id);
            }
        }
    }
}

/// 恢复系统光标（也在启动时调用一次，防止上次异常退出后光标一直是透明的）
pub fn restore_cursors() {
    unsafe { SystemParametersInfoW(SPI_SETCURSORS, 0, null_mut(), 0) };
}

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN_VALUE: &str = "Boundless";

pub fn exe_path() -> String {
    let mut buf = [0u16; 1024];
    let n = unsafe { GetModuleFileNameW(null_mut(), buf.as_mut_ptr(), buf.len() as u32) };
    String::from_utf16_lossy(&buf[..n as usize])
}

pub fn launch_at_login() -> bool {
    unsafe {
        let mut key: HKEY = null_mut();
        if RegOpenKeyExW(HKEY_CURRENT_USER, wide(RUN_KEY).as_ptr(), 0, KEY_QUERY_VALUE, &mut key) != ERROR_SUCCESS {
            return false;
        }
        let found = RegQueryValueExW(key, wide(RUN_VALUE).as_ptr(), null(), null_mut(), null_mut(), null_mut()) == ERROR_SUCCESS;
        RegCloseKey(key);
        found
    }
}

pub fn set_launch_at_login(enabled: bool) {
    unsafe {
        let mut key: HKEY = null_mut();
        if RegOpenKeyExW(HKEY_CURRENT_USER, wide(RUN_KEY).as_ptr(), 0, KEY_SET_VALUE, &mut key) != ERROR_SUCCESS {
            return;
        }
        if enabled {
            let value = wide(&format!("\"{}\"", exe_path()));
            RegSetValueExW(key, wide(RUN_VALUE).as_ptr(), 0, REG_SZ, value.as_ptr() as *const u8, (value.len() * 2) as u32);
        } else {
            RegDeleteValueW(key, wide(RUN_VALUE).as_ptr());
        }
        RegCloseKey(key);
    }
}

pub fn is_elevated() -> bool {
    unsafe {
        let mut token: HANDLE = null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return false;
        }
        let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
        let mut len = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            &mut elevation as *mut _ as _,
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut len,
        );
        CloseHandle(token);
        ok != 0 && elevation.TokenIsElevated != 0
    }
}

/// 以管理员身份重新启动自己（弹出 UAC 确认）。成功发起返回 true，调用方随后退出
pub fn restart_elevated() -> bool {
    let exe = wide(&exe_path());
    let r = unsafe { ShellExecuteW(null_mut(), wide("runas").as_ptr(), exe.as_ptr(), null(), null(), SW_SHOWNORMAL) };
    r as isize > 32
}

/// 保证只运行一个实例。以管理员身份重启时旧进程还没退出，最多等 5 秒
pub fn acquire_single_instance() -> bool {
    let name = wide("Local\\BoundlessSingleInstance");
    for _ in 0..50 {
        let handle = unsafe { CreateMutexW(null(), 0, name.as_ptr()) };
        if !handle.is_null() && unsafe { GetLastError() } != ERROR_ALREADY_EXISTS {
            // 句柄故意不关，进程退出时由系统释放
            return true;
        }
        if !handle.is_null() {
            unsafe { CloseHandle(handle) };
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    false
}

/// 用默认程序打开文件
pub fn open(path: &str) {
    unsafe { ShellExecuteW(null_mut(), wide("open").as_ptr(), wide(path).as_ptr(), null(), null(), SW_SHOWNORMAL) };
}

// MARK: 网卡

struct Adapter {
    index: u32,
    ipv6_index: u32,
    wired: bool,
    ipv4: Vec<Ipv4Addr>,
}

fn adapters() -> Vec<Adapter> {
    let mut size = 16 * 1024u32;
    let mut buf: Vec<u64> = Vec::new();
    unsafe {
        for _ in 0..3 {
            buf = vec![0u64; size as usize / 8 + 1];
            let r = GetAdaptersAddresses(AF_UNSPEC as u32, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, null(), buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH, &mut size);
            if r == ERROR_SUCCESS {
                break;
            }
            if r != ERROR_BUFFER_OVERFLOW {
                return Vec::new();
            }
        }
        let mut out = Vec::new();
        let mut p = buf.as_ptr() as *const IP_ADAPTER_ADDRESSES_LH;
        while !p.is_null() {
            let a = &*p;
            let mut ipv4 = Vec::new();
            let mut u = a.FirstUnicastAddress;
            while !u.is_null() {
                let sa = (*u).Address.lpSockaddr;
                if !sa.is_null() && (*sa).sa_family == AF_INET {
                    let sin = &*(sa as *const SOCKADDR_IN);
                    ipv4.push(Ipv4Addr::from(u32::from_be(sin.sin_addr.S_un.S_addr)));
                }
                u = (*u).Next;
            }
            out.push(Adapter {
                index: a.Anonymous1.Anonymous.IfIndex,
                ipv6_index: a.Ipv6IfIndex,
                wired: a.IfType == IF_TYPE_ETHERNET_CSMACD,
                ipv4,
            });
            p = a.Next;
        }
        out
    }
}

/// 这个接口索引对应的网卡是不是有线（网线、USB / 雷雳直连在 Windows 上都是以太网类型）
pub fn is_wired_interface(index: u32) -> bool {
    adapters().iter().any(|a| (a.index == index || a.ipv6_index == index) && a.wired)
}

/// 本机这个地址所在的网卡是不是有线；查不到时按无线算
pub fn is_wired_local_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => adapters().iter().any(|a| a.wired && a.ipv4.contains(&v4)),
        IpAddr::V6(_) => false,
    }
}
