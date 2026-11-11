use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, UdpSocket};

// Networking over the loopback interface: a TCP echo with a server thread, a UDP datagram, and a refused connection.
// The server thread returns what it saw, so the output is printed in a fixed order.
fn main() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    println!("loopback: {}", addr.ip().is_loopback());

    let server = std::thread::spawn(move || {
        let (mut conn, peer) = listener.accept().unwrap();
        let mut buf = [0u8; 16];
        let n = conn.read(&mut buf).unwrap();
        conn.write_all(b"pong:").unwrap();
        conn.write_all(&buf[..n]).unwrap();
        peer.ip().is_loopback()
    });

    let mut client = TcpStream::connect(addr).unwrap();
    client.write_all(b"ping").unwrap();
    let mut reply = Vec::new();
    client.read_to_end(&mut reply).unwrap();
    println!("tcp reply: {}", String::from_utf8(reply).unwrap());
    println!("peer loopback: {}", server.join().unwrap());

    let rx = UdpSocket::bind("127.0.0.1:0").unwrap();
    let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
    tx.send_to(b"datagram", rx.local_addr().unwrap()).unwrap();
    let mut buf = [0u8; 32];
    let (n, from) = rx.recv_from(&mut buf).unwrap();
    println!("udp: {} from loopback: {}", String::from_utf8_lossy(&buf[..n]), from.ip().is_loopback());

    // Port 1 has no listener here, so the connection is refused.
    match TcpStream::connect("127.0.0.1:1") {
        Ok(_) => println!("connected unexpectedly"),
        Err(e) => println!("refused: {:?}", e.kind()),
    }
}
