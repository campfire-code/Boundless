//! 互通测试用的对端：与 Swift 版建立加密连接，把收到的每条消息原样发回。
//!   peer serve <配对码> <服务名>    监听并通过 mDNS 广播，打印 "READY <端口>"
//!   peer connect <配对码> <服务名>  通过 mDNS 找到这个服务并连接
//! 连接断开后退出，退出码 0 表示连接曾经建立

use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use boundless_core::discovery::{Advertiser, Browser};
use boundless_core::link::{self, Link, LinkEvent, Listener};
use boundless_core::message::{Channel, Message, Platform};
use boundless_core::{pairing, PROTOCOL_VERSION};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (mode, code, name) = match args.as_slice() {
        [_, m, c, n] => (m.clone(), c.clone(), n.clone()),
        _ => {
            eprintln!("用法：peer serve|connect <配对码> <服务名>");
            std::process::exit(2);
        }
    };
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let psk = pairing::preshared_key(&code);
    let (tx, rx) = mpsc::channel::<(u64, LinkEvent)>();
    let tx = std::sync::Mutex::new(tx);
    let sink: link::Sink = Arc::new(move |id, e| drop(tx.lock().unwrap().send((id, e))));

    let mut _keep: Vec<Box<dyn std::any::Any>> = Vec::new();
    let mut link: Option<Link> = None;
    if mode == "serve" {
        let listener = Listener::bind(rt.handle(), psk, Duration::from_secs(8), sink).unwrap();
        let advertiser = Advertiser::start(&name, listener.port()).unwrap();
        println!("READY {}", listener.port());
        _keep.push(Box::new(listener));
        _keep.push(Box::new(advertiser));
    } else {
        let (found_tx, found_rx) = mpsc::channel();
        let target = name.clone();
        let browser = Browser::start(move |services| {
            if let Some(s) = services.get(&target) {
                let _ = found_tx.send(s.socket_addrs());
            }
        })
        .unwrap();
        let addrs = found_rx.recv_timeout(Duration::from_secs(15)).expect("15 秒内没找到服务");
        eprintln!("peer: 找到 {name} {addrs:?}");
        link = Some(link::connect(rt.handle(), addrs, psk, Duration::from_secs(8), sink));
        _keep.push(Box::new(browser));
    }

    let started = Instant::now();
    let mut ready = false;
    loop {
        let Ok((_, event)) = rx.recv_timeout(Duration::from_secs(60)) else { break };
        match event {
            LinkEvent::Accepted(l) => {
                eprintln!("peer: 收到新连接（{:.1}s）", started.elapsed().as_secs_f64());
                link = Some(l);
            }
            LinkEvent::Ready => {
                ready = true;
                eprintln!("peer: 握手完成 {:?}", link.as_ref().and_then(|l| l.addrs()));
                let hello = Message::Hello {
                    version: PROTOCOL_VERSION,
                    name: "Rust 对端".into(),
                    channel: Channel::Control,
                    platform: Platform::Windows,
                };
                link.as_ref().unwrap().send(&hello);
            }
            LinkEvent::Message(m) => link.as_ref().unwrap().send(&m),
            LinkEvent::Closed(e) => {
                eprintln!("peer: 连接关闭 {e:?}（{:.1}s）", started.elapsed().as_secs_f64());
                if mode == "serve" && !ready {
                    // 服务端在握手失败后继续等下一条连接
                    continue;
                }
                break;
            }
        }
    }
    std::process::exit(if ready { 0 } else { 1 });
}
