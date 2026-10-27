use std::net::SocketAddr;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

use boundless_core::link::{self, LinkEvent, Listener, Sink};
use boundless_core::message::Message;
use boundless_core::pairing;

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap()
}

fn sink() -> (Sink, mpsc::Receiver<(u64, LinkEvent)>) {
    let (tx, rx) = mpsc::channel();
    let tx = std::sync::Mutex::new(tx);
    (Arc::new(move |id, e| drop(tx.lock().unwrap().send((id, e)))), rx)
}

fn next(rx: &mpsc::Receiver<(u64, LinkEvent)>) -> (u64, LinkEvent) {
    rx.recv_timeout(Duration::from_secs(10)).expect("等事件超时")
}

#[test]
fn messages_flow_both_ways_and_pings_are_hidden() {
    let rt = runtime();
    let psk = pairing::preshared_key("ABCD-EFGH-JKMN");
    let (server_sink, server_rx) = sink();
    let listener = Listener::bind(rt.handle(), psk, Duration::from_secs(5), server_sink).unwrap();
    let (client_sink, client_rx) = sink();
    let addr: SocketAddr = format!("127.0.0.1:{}", listener.port()).parse().unwrap();
    let client = link::connect(rt.handle(), vec![addr], psk, Duration::from_secs(5), client_sink);

    let LinkEvent::Accepted(server) = next(&server_rx).1 else { panic!("应先收到新连接") };
    assert!(matches!(next(&server_rx).1, LinkEvent::Ready));
    assert!(matches!(next(&client_rx).1, LinkEvent::Ready));

    client.send(&Message::MouseMove { dx: 1.0, dy: -2.0 });
    match next(&server_rx).1 {
        LinkEvent::Message(m) => assert_eq!(m, Message::MouseMove { dx: 1.0, dy: -2.0 }),
        _ => panic!("应收到消息"),
    }
    server.send(&Message::Leave);
    match next(&client_rx).1 {
        LinkEvent::Message(m) => assert_eq!(m, Message::Leave),
        _ => panic!("应收到消息"),
    }

    // 2.5 秒内心跳照常往来，但 ping 不会交给上层，连接也不会断
    assert!(client_rx.recv_timeout(Duration::from_millis(2500)).is_err());
    assert_eq!(client.backlog(), 0);
    assert!(client.addrs().is_some());

    client.cancel();
    assert!(matches!(next(&client_rx).1, LinkEvent::Closed(None)));
    assert!(matches!(next(&server_rx).1, LinkEvent::Closed(_)));
}

#[test]
fn wrong_pairing_code_fails_handshake() {
    let rt = runtime();
    let (server_sink, server_rx) = sink();
    let listener =
        Listener::bind(rt.handle(), pairing::preshared_key("ABCD-EFGH-JKMN"), Duration::from_secs(5), server_sink).unwrap();
    let (client_sink, client_rx) = sink();
    let addr: SocketAddr = format!("127.0.0.1:{}", listener.port()).parse().unwrap();
    let _client = link::connect(
        rt.handle(),
        vec![addr],
        pairing::preshared_key("ABCD-EFGH-JKMP"),
        Duration::from_secs(5),
        client_sink,
    );
    match next(&client_rx).1 {
        LinkEvent::Closed(Some(e)) => assert!(e.contains("握手"), "{e}"),
        _ => panic!("配对码错误应握手失败"),
    }
    assert!(matches!(next(&server_rx).1, LinkEvent::Accepted(_)));
    assert!(matches!(next(&server_rx).1, LinkEvent::Closed(Some(_))));
}

#[test]
fn unreachable_address_reports_error() {
    let rt = runtime();
    let (client_sink, client_rx) = sink();
    // 端口 1 基本不会有人监听，连接会被拒绝
    let _client = link::connect(
        rt.handle(),
        vec!["127.0.0.1:1".parse().unwrap()],
        pairing::preshared_key("ABCD-EFGH-JKMN"),
        Duration::from_secs(5),
        client_sink,
    );
    assert!(matches!(next(&client_rx).1, LinkEvent::Closed(Some(_))));
}

#[test]
fn instance_names_are_unescaped() {
    use boundless_core::discovery::instance_name;
    assert_eq!(instance_name("Mac\\.mini._boundless._tcp.local."), "Mac.mini");
    assert_eq!(instance_name("康霖的 MacBook Pro._boundless._tcp.local."), "康霖的 MacBook Pro");
    assert_eq!(instance_name("A\\032B._boundless._tcp.local."), "A B");
}
