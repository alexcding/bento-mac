//! Bento protocol plugin for Bilibili: reads one JSON-RPC 2.0 request from stdin, writes the
//! response to stdout. Methods: `auth/begin`, `auth/step` (TV QR login) and `source/fetch`
//! (the logged-in user's following feed).

mod auth;
mod feed;

use std::io::Read;

use serde_json::{Value, json};

/// JSON-RPC error code the host treats as "sign in again".
const AUTH_REQUIRED: i64 = -32001;

/// A failed request: a JSON-RPC error code and message.
#[derive(Debug)]
pub struct Failure {
    pub code: i64,
    pub message: String,
}

impl Failure {
    fn auth(message: impl Into<String>) -> Self {
        Self {
            code: AUTH_REQUIRED,
            message: message.into(),
        }
    }

    fn other(message: impl Into<String>) -> Self {
        Self {
            code: -32000,
            message: message.into(),
        }
    }
}

impl From<reqwest::Error> for Failure {
    fn from(error: reqwest::Error) -> Self {
        Self::other(format!("request failed: {error}"))
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mut input = String::new();
    let response = match std::io::stdin().read_to_string(&mut input) {
        Ok(_) => handle(&input).await,
        Err(error) => error_response(&Value::Null, &Failure::other(error.to_string())),
    };
    println!("{response}");
}

async fn handle(input: &str) -> Value {
    let Ok(request) = serde_json::from_str::<Value>(input) else {
        return json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "parse error"}});
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    let client = match reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh) Bento/0.1")
        .timeout(std::time::Duration::from_secs(30))
        .build()
    {
        Ok(client) => client,
        Err(error) => return error_response(&id, &Failure::from(error)),
    };
    let endpoints = Endpoints::default();
    let result = match request.get("method").and_then(Value::as_str) {
        Some("auth/begin") => auth::begin(&client, &endpoints).await,
        Some("auth/step") => auth::step(&client, &endpoints, &params).await,
        Some("source/fetch") => feed::fetch(&client, &endpoints, &params).await,
        Some(other) => Err(Failure {
            code: -32601,
            message: format!("unknown method {other}"),
        }),
        None => Err(Failure {
            code: -32600,
            message: "missing method".into(),
        }),
    };
    match result {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err(failure) => error_response(&id, &failure),
    }
}

fn error_response(id: &Value, failure: &Failure) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": failure.code, "message": failure.message}})
}

/// Base URLs, replaceable in tests.
pub struct Endpoints {
    pub passport: String,
    pub api: String,
}

impl Default for Endpoints {
    fn default() -> Self {
        Self {
            passport: "https://passport.bilibili.com".into(),
            api: "https://api.bilibili.com".into(),
        }
    }
}
