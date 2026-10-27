//! 加密消息通道：TLS 1.2 预共享密钥 + 分帧 + 心跳 + 断线检测，与 Swift 版 Transport.swift 互通。
//! 事件统一交给 Sink 回调（在网络线程上调用），由上层转到界面线程处理

use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use openssl::ssl::{Ssl, SslContext, SslMethod, SslVerifyMode, SslVersion};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, watch};
use tokio_openssl::SslStream;

use crate::message::{encode_frame, FrameDecoder, Message};

pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(1);
pub const TIMEOUT: Duration = Duration::from_secs(4);
const TCP_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const PSK_IDENTITY: &[u8] = b"boundless";
const CIPHER: &str = "PSK-AES128-GCM-SHA256";

pub enum LinkEvent {
    /// 主控端监听到一条新连接（握手还没完成）
    Accepted(Link),
    Ready,
    Message(Message),
    /// 连接已关闭；None 表示主动断开或对方正常关闭
    Closed(Option<String>),
}

/// 事件回调：(连接编号, 事件)
pub type Sink = Arc<dyn Fn(u64, LinkEvent) + Send + Sync>;

#[derive(Clone)]
pub struct Link {
    inner: Arc<Inner>,
}

struct Inner {
    id: u64,
    out: mpsc::UnboundedSender<Vec<u8>>,
    backlog: AtomicUsize,
    cancel: watch::Sender<bool>,
    addrs: Mutex<Option<(SocketAddr, SocketAddr)>>,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

impl Link {
    fn new() -> (Link, mpsc::UnboundedReceiver<Vec<u8>>, watch::Receiver<bool>) {
        let (out, out_rx) = mpsc::unbounded_channel();
        let (cancel, cancel_rx) = watch::channel(false);
        let inner = Inner {
            id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
            out,
            backlog: AtomicUsize::new(0),
            cancel,
            addrs: Mutex::new(None),
        };
        (Link { inner: Arc::new(inner) }, out_rx, cancel_rx)
    }

    pub fn id(&self) -> u64 {
        self.inner.id
    }

    pub fn send(&self, message: &Message) {
        self.inner.backlog.fetch_add(1, Ordering::Relaxed);
        if self.inner.out.send(encode_frame(message)).is_err() {
            self.inner.backlog.fetch_sub(1, Ordering::Relaxed);
        }
    }

    /// 已排队、还没写进系统的消息数
    pub fn backlog(&self) -> usize {
        self.inner.backlog.load(Ordering::Relaxed)
    }

    pub fn cancel(&self) {
        let _ = self.inner.cancel.send(true);
    }

    /// (本机地址, 对方地址)，TCP 连上之后才有
    pub fn addrs(&self) -> Option<(SocketAddr, SocketAddr)> {
        *self.inner.addrs.lock().unwrap()
    }
}

fn context(psk: [u8; 32], server: bool) -> Result<SslContext, openssl::error::ErrorStack> {
    let mut b = SslContext::builder(SslMethod::tls())?;
    b.set_min_proto_version(Some(SslVersion::TLS1_2))?;
    b.set_max_proto_version(Some(SslVersion::TLS1_2))?;
    b.set_cipher_list(CIPHER)?;
    b.set_verify(SslVerifyMode::NONE);
    if server {
        b.set_psk_server_callback(move |_, _identity, out| {
            out[..psk.len()].copy_from_slice(&psk);
            Ok(psk.len())
        });
    } else {
        b.set_psk_client_callback(move |_, _hint, identity, out| {
            // identity 是以 NUL 结尾的 C 字符串
            identity[..PSK_IDENTITY.len()].copy_from_slice(PSK_IDENTITY);
            identity[PSK_IDENTITY.len()] = 0;
            out[..psk.len()].copy_from_slice(&psk);
            Ok(psk.len())
        });
    }
    Ok(b.build())
}

/// 被控端：按顺序尝试这些地址，连上第一个能连的
pub fn connect(rt: &Handle, addrs: Vec<SocketAddr>, psk: [u8; 32], handshake_timeout: Duration, sink: Sink) -> Link {
    let (link, out_rx, cancel_rx) = Link::new();
    let l = link.clone();
    rt.spawn(async move {
        let id = l.id();
        let result = async {
            let ctx = context(psk, false).map_err(|e| e.to_string())?;
            let deadline = Instant::now() + handshake_timeout;
            let tcp = connect_any(&addrs).await?;
            let ssl = Ssl::new(&ctx).map_err(|e| e.to_string())?;
            run(l, tcp, ssl, false, deadline, out_rx, cancel_rx, sink.clone()).await
        }
        .await;
        sink(id, LinkEvent::Closed(result.err().filter(|e| !e.is_empty())));
    });
    link
}

async fn connect_any(addrs: &[SocketAddr]) -> Result<TcpStream, String> {
    let mut last = "没有可用的地址".to_string();
    for addr in addrs {
        match tokio::time::timeout(TCP_CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
            Ok(Ok(s)) => return Ok(s),
            Ok(Err(e)) => last = format!("连接 {addr} 失败：{e}"),
            Err(_) => last = format!("连接 {addr} 超时"),
        }
    }
    Err(last)
}

/// 主控端监听
pub struct Listener {
    port: u16,
    cancel: watch::Sender<bool>,
}

impl Listener {
    pub fn bind(rt: &Handle, psk: [u8; 32], handshake_timeout: Duration, sink: Sink) -> io::Result<Listener> {
        let ctx = context(psk, true).map_err(io::Error::other)?;
        let std_listener = std::net::TcpListener::bind(("0.0.0.0", 0))?;
        std_listener.set_nonblocking(true)?;
        let port = std_listener.local_addr()?.port();
        let (cancel, mut cancel_rx) = watch::channel(false);
        let _guard = rt.enter();
        let listener = TcpListener::from_std(std_listener)?;
        rt.spawn(async move {
            loop {
                let accepted = tokio::select! {
                    a = listener.accept() => a,
                    _ = cancel_rx.changed() => return,
                };
                let Ok((tcp, _)) = accepted else { continue };
                let Ok(ssl) = Ssl::new(&ctx) else { continue };
                let (link, out_rx, link_cancel) = Link::new();
                sink(link.id(), LinkEvent::Accepted(link.clone()));
                let sink = sink.clone();
                tokio::spawn(async move {
                    let id = link.id();
                    let deadline = Instant::now() + handshake_timeout;
                    let result = run(link, tcp, ssl, true, deadline, out_rx, link_cancel, sink.clone()).await;
                    sink(id, LinkEvent::Closed(result.err().filter(|e| !e.is_empty())));
                });
            }
        });
        Ok(Listener { port, cancel })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn cancel(&self) {
        let _ = self.cancel.send(true);
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.cancel();
    }
}

/// 握手、收发、心跳，直到连接结束。返回 Err("") 表示主动断开
#[allow(clippy::too_many_arguments)]
async fn run(
    link: Link,
    tcp: TcpStream,
    ssl: Ssl,
    server: bool,
    deadline: Instant,
    mut out_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    mut cancel_rx: watch::Receiver<bool>,
    sink: Sink,
) -> Result<(), String> {
    let id = link.id();
    let _ = tcp.set_nodelay(true);
    if let (Ok(local), Ok(peer)) = (tcp.local_addr(), tcp.peer_addr()) {
        *link.inner.addrs.lock().unwrap() = Some((local, peer));
    }
    let mut stream = SslStream::new(ssl, tcp).map_err(|e| e.to_string())?;
    let handshake = async {
        if server {
            Pin::new(&mut stream).accept().await
        } else {
            Pin::new(&mut stream).connect().await
        }
    };
    let remaining = deadline.saturating_duration_since(Instant::now());
    tokio::select! {
        r = tokio::time::timeout(remaining, handshake) => match r {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(format!("握手失败（配对码可能不正确）：{e}")),
            Err(_) => return Err("握手超时（配对码可能不正确）".into()),
        },
        _ = cancel_rx.changed() => return Err(String::new()),
    }

    sink(id, LinkEvent::Ready);
    let (mut rd, mut wr) = tokio::io::split(stream);
    let last_received = Arc::new(Mutex::new(Instant::now()));

    let reader = {
        let last_received = last_received.clone();
        let sink = sink.clone();
        async move {
            let mut decoder = FrameDecoder::default();
            let mut buf = vec![0u8; 1 << 16];
            loop {
                let n = rd.read(&mut buf).await.map_err(|e| e.to_string())?;
                if n == 0 {
                    return Err::<(), String>(String::new());
                }
                *last_received.lock().unwrap() = Instant::now();
                for m in decoder.append(&buf[..n]).map_err(|e| e.to_string())? {
                    if m != Message::Ping {
                        sink(id, LinkEvent::Message(m));
                    }
                }
            }
        }
    };

    let writer = {
        let link = link.clone();
        async move {
            let mut ticker = tokio::time::interval(HEARTBEAT_INTERVAL);
            ticker.tick().await;
            loop {
                tokio::select! {
                    frame = out_rx.recv() => {
                        let Some(frame) = frame else { return Err::<(), String>(String::new()) };
                        let r = wr.write_all(&frame).await;
                        link.inner.backlog.fetch_sub(1, Ordering::Relaxed);
                        r.map_err(|e| e.to_string())?;
                    }
                    _ = ticker.tick() => {
                        if last_received.lock().unwrap().elapsed() > TIMEOUT {
                            return Err("心跳超时".into());
                        }
                        wr.write_all(&encode_frame(&Message::Ping)).await.map_err(|e| e.to_string())?;
                    }
                }
            }
        }
    };

    tokio::select! {
        r = reader => r,
        r = writer => r,
        _ = cancel_rx.changed() => Err(String::new()),
    }
}
