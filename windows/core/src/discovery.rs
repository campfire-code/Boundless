//! 局域网发现：用 mDNS 浏览 / 广播 _boundless._tcp，与 Mac 版的 Bonjour 互通

use std::collections::HashMap;
use std::net::{SocketAddr, SocketAddrV6};

use mdns_sd::{IfKind, ScopedIp, ServiceDaemon, ServiceEvent, ServiceInfo};

use crate::SERVICE_TYPE;

/// 主控端的一个地址，以及在本机哪块网卡上发现的（网卡编号即系统的接口索引，用来判断是否有线）
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FoundAddr {
    pub addr: SocketAddr,
    pub interface: Option<u32>,
}

/// 发现的一台主控端
#[derive(Debug, Clone, PartialEq)]
pub struct FoundService {
    pub name: String,
    /// 按优先顺序：IPv4、带作用域的 IPv6 链路本地地址，回环地址放最后（只在同一台机器上测试时有用）
    pub addrs: Vec<FoundAddr>,
}

impl FoundService {
    pub fn socket_addrs(&self) -> Vec<SocketAddr> {
        self.addrs.iter().map(|a| a.addr).collect()
    }
}

/// 被控端：查找局域网内的主控端，列表变化时回调（在后台线程上）
pub struct Browser {
    daemon: ServiceDaemon,
}

impl Browser {
    pub fn start(on_change: impl Fn(HashMap<String, FoundService>) + Send + 'static) -> Result<Browser, String> {
        let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
        let rx = daemon.browse(SERVICE_TYPE).map_err(|e| e.to_string())?;
        std::thread::Builder::new()
            .name("boundless-browser".into())
            .spawn(move || {
                let mut found: HashMap<String, FoundService> = HashMap::new();
                while let Ok(event) = rx.recv() {
                    match event {
                        ServiceEvent::ServiceResolved(info) => {
                            let name = instance_name(&info.fullname);
                            let addrs = addresses(info.get_addresses().iter(), info.get_port());
                            // 苹果的 Bonjour 常先只报回环或部分地址，随后再补全；一个可用地址都没有时先不上报
                            if addrs.is_empty() {
                                continue;
                            }
                            found.insert(name.clone(), FoundService { name, addrs });
                        }
                        ServiceEvent::ServiceRemoved(_, fullname) => {
                            found.remove(&instance_name(&fullname));
                        }
                        ServiceEvent::SearchStopped(_) => break,
                        _ => continue,
                    }
                    on_change(found.clone());
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(Browser { daemon })
    }
}

impl Drop for Browser {
    fn drop(&mut self) {
        let _ = self.daemon.shutdown();
    }
}

/// 主控端：广播本机服务
pub struct Advertiser {
    daemon: ServiceDaemon,
}

impl Advertiser {
    pub fn start(name: &str, port: u16) -> Result<Advertiser, String> {
        let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
        // 只广播 IPv4：监听只开在 IPv4 上；而且自动模式会把所有 IPv6 链路本地地址挂到每块网卡上，
        // 苹果的连接逻辑优先挨个尝试这些连不通的地址，偶尔会拖过握手时限
        daemon.disable_interface(IfKind::IPv6).map_err(|e| e.to_string())?;
        let host = format!("{}.local.", host_label(name));
        let info = ServiceInfo::new(SERVICE_TYPE, name, &host, "", port, None::<HashMap<String, String>>)
            .map_err(|e| e.to_string())?
            .enable_addr_auto();
        daemon.register(info).map_err(|e| e.to_string())?;
        Ok(Advertiser { daemon })
    }
}

impl Drop for Advertiser {
    fn drop(&mut self) {
        let _ = self.daemon.shutdown();
    }
}

fn addresses<'a>(ips: impl Iterator<Item = &'a ScopedIp>, port: u16) -> Vec<FoundAddr> {
    let mut out: Vec<(u8, FoundAddr)> = Vec::new();
    for ip in ips {
        match ip {
            ScopedIp::V4(v4) => {
                let a = *v4.addr();
                if a.is_unspecified() {
                    continue;
                }
                let interface = v4.interface_ids().first().map(|i| i.index);
                out.push((if a.is_loopback() { 2 } else { 0 }, FoundAddr { addr: SocketAddr::new(a.into(), port), interface }));
            }
            ScopedIp::V6(v6) => {
                let a = *v6.addr();
                if a.is_unspecified() || a.is_loopback() {
                    continue;
                }
                let index = v6.scope_id().index;
                let link_local = (a.segments()[0] & 0xffc0) == 0xfe80;
                let addr = SocketAddr::V6(SocketAddrV6::new(a, port, 0, if link_local { index } else { 0 }));
                out.push((1, FoundAddr { addr, interface: Some(index) }));
            }
            _ => {}
        }
    }
    out.sort_by_key(|(rank, a)| (*rank, a.addr));
    out.dedup_by_key(|(_, a)| a.addr);
    out.into_iter().map(|(_, a)| a).collect()
}

/// "Mac\.mini._boundless._tcp.local." → "Mac.mini"
pub fn instance_name(fullname: &str) -> String {
    let raw = fullname.strip_suffix(&format!(".{SERVICE_TYPE}")).unwrap_or(fullname);
    let mut out = Vec::new();
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            // \DDD 十进制转义，或 \. \\ 之类的字面转义
            if i + 3 < bytes.len() && bytes[i + 1..i + 4].iter().all(u8::is_ascii_digit) {
                let v = std::str::from_utf8(&bytes[i + 1..i + 4]).unwrap().parse::<u16>().unwrap_or(0);
                out.push(v.min(255) as u8);
                i += 4;
                continue;
            }
            out.push(bytes[i + 1]);
            i += 2;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// mDNS 主机名：只用字母数字和横线，加 boundless- 前缀免得和系统自己广播的 <计算机名>.local 冲突，
/// 末尾带名称的哈希，中文名之类转换后为空或相同时也不会撞名
fn host_label(name: &str) -> String {
    let s: String = name.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let s = s.trim_matches('-');
    let hash = name.bytes().fold(0x811c9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x01000193));
    let base: String = if s.is_empty() { "pc".into() } else { s.chars().take(40).collect() };
    format!("boundless-{base}-{:04x}", hash & 0xFFFF)
}

#[cfg(test)]
mod tests {
    #[test]
    fn host_labels_are_valid_and_distinct() {
        let a = super::host_label("康霖的电脑");
        let b = super::host_label("书房的电脑");
        assert!(a.starts_with("boundless-pc-") && b.starts_with("boundless-pc-"));
        assert_ne!(a, b, "中文名转换后都是 pc，靠哈希区分");
        assert!(super::host_label("DESKTOP-AB12").starts_with("boundless-DESKTOP-AB12-"));
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'));
    }
}
