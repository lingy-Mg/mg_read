//! One HTTP listener per initialized plugin, inside the shared worker process.
//! Each connection owns its handler future; disconnect drops it and its upstream
//! request. No call-id registry, cancellation RPC, polling or worker per plugin.
use axum::{Router, body::Body};
use hyper::{body::Incoming, service::service_fn};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio_util::sync::CancellationToken;
use tower::ServiceExt;

pub async fn serve(listener: tokio::net::TcpListener, router: Router, stop: CancellationToken) {
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            biased;
            _ = stop.cancelled() => break,
            Some(_) = connections.join_next(), if !connections.is_empty() => {},
            accepted = listener.accept() => {
                let Ok((socket, _)) = accepted else { break };
                let router = router.clone();
                let stop = stop.clone();
                connections.spawn(async move {
                    let connection_stop = stop.child_token();
                    let cancellation = connection_stop.clone();
                    let service = service_fn(move |mut request: hyper::Request<Incoming>| {
                        request.extensions_mut().insert(cancellation.clone());
                        router.clone().oneshot(request.map(Body::new))
                    });
                    let mut builder = hyper::server::conn::http1::Builder::new();
                    builder.timer(TokioTimer::new()).half_close(false).max_buf_size(64 * 1024);
                    tokio::select! {
                        _ = stop.cancelled() => {},
                        _ = builder.serve_connection(TokioIo::new(socket), service) => {},
                    }
                    connection_stop.cancel();
                });
            }
        }
    }
    connections.abort_all();
    while connections.join_next().await.is_some() {}
}
