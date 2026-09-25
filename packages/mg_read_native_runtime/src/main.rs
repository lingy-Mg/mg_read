//! Windows worker entry. stdout is only the private bootstrap descriptor; stderr
//! receives bounded operational errors. The Flutter supervisor owns its lifetime.
use std::path::PathBuf;
#[tokio::main]
async fn main() {
    let args = std::env::args().collect::<Vec<_>>();
    let value = |flag: &str| {
        args.iter()
            .position(|v| v == flag)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let Some(root) = value("--root") else {
        eprintln!("missing native data root");
        std::process::exit(2)
    };
    let Some(token) = value("--token") else {
        eprintln!("missing native token");
        std::process::exit(2)
    };
    if let Err(e) = mgread_native_runtime::serve(
        PathBuf::from(root),
        token,
        args.iter().any(|a| a == "--test-mode"),
        |ready| {
            use std::io::Write;
            println!("{ready}");
            let _ = std::io::stdout().flush();
        },
    )
    .await
    {
        eprintln!("{e}");
        std::process::exit(1)
    }
}
