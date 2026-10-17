//! TV QR login: request a QR code, then poll until the user scans and confirms it in the Bilibili
//! app. The cookies from the confirmation become the plugin's secrets.

use serde_json::{Value, json};

use crate::{Endpoints, Failure};

/// Public TV-client credentials used to sign login requests.
const APP_KEY: &str = "4409e2ce8ffd12b8";
const APP_SECRET: &str = "59b43e04ad6965f34319062b478f83dd";
const POLL_INTERVAL_MS: u64 = 2_000;
/// How long a QR code stays usable.
const LOGIN_TIMEOUT_SECS: i64 = 180;

pub async fn begin(client: &reqwest::Client, endpoints: &Endpoints) -> Result<Value, Failure> {
    let now = chrono::Utc::now().timestamp();
    let body = sign(&[("local_id", "0".into()), ("ts", now.to_string())]);
    let reply = post(
        client,
        &format!(
            "{}/x/passport-tv-login/qrcode/auth_code",
            endpoints.passport
        ),
        body,
    )
    .await?;
    let data = reply
        .get("data")
        .ok_or_else(|| Failure::other("no data in QR code reply"))?;
    let url = data
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::other("no QR code URL"))?;
    let auth_code = data
        .get("auth_code")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::other("no auth code"))?;
    Ok(json!({
        "status": "pending",
        "state": json!({"auth_code": auth_code, "qr": url, "expires_at": now + LOGIN_TIMEOUT_SECS}).to_string(),
        "prompt": {"kind": "qr", "message": "Scan this QR code with the Bilibili app and confirm.", "qr": url},
        "poll_after_ms": POLL_INTERVAL_MS
    }))
}

pub async fn step(
    client: &reqwest::Client,
    endpoints: &Endpoints,
    params: &Value,
) -> Result<Value, Failure> {
    let state: Value = params
        .get("state")
        .and_then(Value::as_str)
        .and_then(|s| serde_json::from_str(s).ok())
        .ok_or_else(|| Failure::other("missing login state"))?;
    let auth_code = state
        .get("auth_code")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let now = chrono::Utc::now().timestamp();
    if state
        .get("expires_at")
        .and_then(Value::as_i64)
        .is_some_and(|at| now > at)
    {
        return Ok(failed("The QR code expired. Start again."));
    }
    let body = sign(&[
        ("auth_code", auth_code.into()),
        ("local_id", "0".into()),
        ("ts", now.to_string()),
    ]);
    let reply = post_raw(
        client,
        &format!("{}/x/passport-tv-login/qrcode/poll", endpoints.passport),
        body,
    )
    .await?;
    let pending = |message: &str| {
        json!({
            "status": "pending",
            "state": state.to_string(),
            "prompt": {"kind": "qr", "message": message, "qr": state.get("qr").cloned().unwrap_or(Value::Null)},
            "poll_after_ms": POLL_INTERVAL_MS
        })
    };
    match reply.get("code").and_then(Value::as_i64) {
        Some(86039) => Ok(pending(
            "Scan this QR code with the Bilibili app and confirm.",
        )),
        Some(86090) => Ok(pending("Scanned. Confirm the login on your phone.")),
        Some(86038) => Ok(failed("The QR code expired. Start again.")),
        Some(0) => Ok(done(reply.get("data").unwrap_or(&Value::Null))),
        _ => Ok(failed(
            reply
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("login failed"),
        )),
    }
}

fn done(data: &Value) -> Value {
    let cookie = |name: &str| {
        data.pointer("/cookie_info/cookies")
            .and_then(Value::as_array)
            .and_then(|cookies| {
                cookies
                    .iter()
                    .find(|c| c.get("name").and_then(Value::as_str) == Some(name))
            })
            .and_then(|c| c.get("value").and_then(Value::as_str))
            .unwrap_or_default()
            .to_owned()
    };
    let sessdata = cookie("SESSDATA");
    if sessdata.is_empty() {
        return failed("Bilibili did not return a session. Try again.");
    }
    let refresh_token = data
        .get("refresh_token")
        .and_then(Value::as_str)
        .unwrap_or_default();
    json!({
        "status": "done",
        "save_secrets": {
            "sessdata": sessdata,
            "bili_jct": cookie("bili_jct"),
            "buvid3": cookie("buvid3"),
            "buvid4": cookie("buvid4"),
            "dedeuserid": cookie("DedeUserID"),
            "refresh_token": refresh_token,
        }
    })
}

fn failed(message: &str) -> Value {
    json!({"status": "failed", "error": message})
}

/// Sorted, form-encoded parameters with `appkey`, plus `sign` = MD5(query + app secret).
fn sign(params: &[(&str, String)]) -> String {
    let mut all: Vec<(&str, String)> = params.to_vec();
    all.push(("appkey", APP_KEY.into()));
    all.sort_by(|a, b| a.0.cmp(b.0));
    let query = all
        .iter()
        .map(|(k, v)| format!("{k}={}", form_encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    let digest = md5::compute(format!("{query}{APP_SECRET}"));
    format!("{query}&sign={digest:x}")
}

fn form_encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => {
                char::from(b).to_string()
            }
            b' ' => "+".into(),
            other => format!("%{other:02X}"),
        })
        .collect()
}

/// POSTs and requires `code == 0`.
async fn post(client: &reqwest::Client, url: &str, body: String) -> Result<Value, Failure> {
    let reply = post_raw(client, url, body).await?;
    match reply.get("code").and_then(Value::as_i64) {
        Some(0) => Ok(reply),
        _ => Err(Failure::other(
            reply
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("Bilibili error")
                .to_owned(),
        )),
    }
}

async fn post_raw(client: &reqwest::Client, url: &str, body: String) -> Result<Value, Failure> {
    let response = client
        .post(url)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await?
        .error_for_status()?;
    Ok(response.json().await?)
}

#[cfg(test)]
mod tests {
    use wiremock::matchers::{body_string_contains, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    use super::*;

    #[test]
    fn signs_like_the_tv_client() {
        // Vector computed independently with Python's hashlib and urllib.
        assert_eq!(
            sign(&[("local_id", "0".into()), ("ts", "1792141200".into())]),
            "appkey=4409e2ce8ffd12b8&local_id=0&ts=1792141200&sign=ee4fd6f28959b79a0d54b5d64bd0c12c"
        );
    }

    fn endpoints(server: &MockServer) -> Endpoints {
        Endpoints {
            passport: server.uri(),
            api: server.uri(),
        }
    }

    #[tokio::test]
    async fn begin_returns_a_qr_prompt_and_step_saves_cookies_on_success() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/x/passport-tv-login/qrcode/auth_code"))
            .respond_with(ResponseTemplate::new(200).set_body_json(
                json!({"code": 0, "data": {"url": "https://passport.bilibili.com/x/qr?c=1", "auth_code": "abc"}}),
            ))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path("/x/passport-tv-login/qrcode/poll"))
            .and(body_string_contains("auth_code=abc"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"code": 0, "data": {
                "refresh_token": "rt",
                "cookie_info": {"cookies": [{"name": "SESSDATA", "value": "s%2C1"}, {"name": "bili_jct", "value": "j"},
                                            {"name": "DedeUserID", "value": "42"}]}
            }})))
            .mount(&server)
            .await;
        let client = reqwest::Client::new();

        let first = begin(&client, &endpoints(&server)).await.unwrap();
        assert_eq!(first["prompt"]["kind"], "qr");
        assert_eq!(
            first["prompt"]["qr"],
            "https://passport.bilibili.com/x/qr?c=1"
        );

        let done = step(
            &client,
            &endpoints(&server),
            &json!({"state": first["state"]}),
        )
        .await
        .unwrap();
        assert_eq!(done["status"], "done");
        assert_eq!(done["save_secrets"]["sessdata"], "s%2C1");
        assert_eq!(done["save_secrets"]["dedeuserid"], "42");
        assert_eq!(done["save_secrets"]["refresh_token"], "rt");
    }

    #[tokio::test]
    async fn step_maps_waiting_scanned_and_expired() {
        let client = reqwest::Client::new();
        let state = json!({"state": json!({"auth_code": "a", "expires_at": i64::MAX}).to_string()});
        for (code, status, needle) in [
            (86039, "pending", "Scan"),
            (86090, "pending", "Confirm"),
            (86038, "failed", "expired"),
        ] {
            let server = MockServer::start().await;
            Mock::given(method("POST"))
                .respond_with(
                    ResponseTemplate::new(200).set_body_json(json!({"code": code, "message": "m"})),
                )
                .mount(&server)
                .await;
            let reply = step(&client, &endpoints(&server), &state).await.unwrap();
            assert_eq!(reply["status"], status, "{code}");
            assert!(reply.to_string().contains(needle), "{code}: {reply}");
        }
    }

    #[tokio::test]
    async fn expired_state_fails_without_calling_bilibili() {
        let client = reqwest::Client::new();
        let state = json!({"state": json!({"auth_code": "a", "expires_at": 0}).to_string()});
        let reply = step(
            &client,
            &Endpoints {
                passport: "http://127.0.0.1:9".into(),
                api: String::new(),
            },
            &state,
        )
        .await
        .unwrap();
        assert_eq!(reply["status"], "failed");
    }
}
