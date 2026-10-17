//! Telegram as the user's own account, over `MTProto` (grammers): sign-in, private channels as a
//! source, and sending to a chat. Each request is a fresh process, so the session (the
//! authorization key per data center) travels as JSON in the `session` secret, and a login in
//! progress carries it in its opaque `state`.

use std::sync::Arc;

use bento_domain::{Author, RawItem};
use grammers_client::client::PasswordToken;
use grammers_client::message::InputMessage;
use grammers_client::sender::{ConnectionParams, NoRetries};
use grammers_client::session::storages::MemorySession;
use grammers_client::session::types::{DcOption, PeerKind};
use grammers_client::session::{Session, SessionData};
use grammers_client::{Client, InvocationError, SenderPool, SignInError, tl};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::task::JoinHandle;

use crate::Failure;

/// The secrets an account login saves: the app credentials and the session.
const API_ID: &str = "api_id";
const API_HASH: &str = "api_hash";
const SESSION: &str = "session";

/// The data centers whose keys are kept. Telegram's primary DCs are 1 to 5.
const DC_IDS: std::ops::RangeInclusive<i32> = 1..=5;

#[derive(Serialize, Deserialize)]
struct StoredSession {
    home_dc: i32,
    dc_options: Vec<DcOption>,
}

/// A connected client and the session it writes to.
struct Connection {
    client: Client,
    session: Arc<MemorySession>,
    runner: JoinHandle<()>,
}

impl Connection {
    fn open(api_id: i32, stored: Option<&str>) -> Result<Self, Failure> {
        let mut data = SessionData::default();
        if let Some(stored) = stored {
            let stored: StoredSession = serde_json::from_str(stored).map_err(|_| {
                Failure::auth("the saved Telegram session is unreadable; sign in again")
            })?;
            data.home_dc = stored.home_dc;
            for option in stored.dc_options {
                data.dc_options.insert(option.id, option);
            }
        }
        let session = Arc::new(MemorySession::from(data));
        // Flood waits come back as errors, so the host can wait them out across runs.
        let params = ConnectionParams {
            device_model: "Mac".into(),
            app_version: concat!("Bento ", env!("CARGO_PKG_VERSION")).into(),
            retry_policy: Box::new(NoRetries),
            ..ConnectionParams::default()
        };
        let SenderPool { runner, handle, .. } =
            SenderPool::with_configuration(Arc::clone(&session), api_id, params);
        let runner = tokio::spawn(runner.run());
        Ok(Self {
            client: Client::new(handle),
            session,
            runner,
        })
    }

    /// The session as stored in the `session` secret.
    fn export(&self) -> Result<String, Failure> {
        let home_dc = self.session.home_dc_id().map_err(other)?;
        let mut dc_options = Vec::new();
        for id in DC_IDS {
            if let Some(option) = self.session.dc_option(id).map_err(other)? {
                dc_options.push(option);
            }
        }
        serde_json::to_string(&StoredSession {
            home_dc,
            dc_options,
        })
        .map_err(other)
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        self.client.disconnect();
        self.runner.abort();
    }
}

fn other(error: impl std::fmt::Display) -> Failure {
    Failure::other(error.to_string())
}

/// Maps a Telegram error: a flood wait asks the host to wait, a revoked session to sign in again.
fn rpc(error: InvocationError) -> Failure {
    if let InvocationError::Rpc(rpc) = &error {
        if rpc.code == 420 {
            return Failure::rate_limited(u64::from(rpc.value.unwrap_or(60)));
        }
        if rpc.code == 401 {
            return Failure::auth(format!("Telegram signed this session out ({})", rpc.name));
        }
        if rpc.code == 400 || rpc.code == 403 {
            return Failure::rejected(format!("Telegram refused: {}", rpc.name));
        }
    }
    other(error)
}

/// Maps an error from the send itself. Only a definite refusal from Telegram (a 4xx answer)
/// means nothing was posted; a lost connection, an unreadable reply or a server-side failure may
/// come after the message went out, so those are reported as uncertain and never retried.
fn send_error(error: InvocationError) -> Failure {
    match error {
        InvocationError::Rpc(rpc_error) if (400..500).contains(&rpc_error.code) => {
            rpc(InvocationError::Rpc(rpc_error))
        }
        other => Failure::uncertain(format!(
            "the send may have been posted, so it is not retried ({other})"
        )),
    }
}

fn secret<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params
        .pointer(&format!("/secrets/{key}"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

fn signed_in(params: &Value) -> Result<(i32, &str), Failure> {
    let api_id = secret(params, API_ID).and_then(|id| id.trim().parse().ok());
    match (api_id, secret(params, SESSION)) {
        (Some(api_id), Some(session)) => Ok((api_id, session)),
        _ => Err(Failure::auth("sign in to Telegram in Settings → Plugins")),
    }
}

// MARK: Login

/// Where a login is, carried in the step `state` between runs.
#[derive(Serialize, Deserialize)]
#[serde(tag = "stage", rename_all = "snake_case")]
enum Stage {
    ApiId,
    ApiHash {
        api_id: i32,
    },
    Phone {
        api_id: i32,
        api_hash: String,
    },
    Code {
        api_id: i32,
        api_hash: String,
        phone: String,
        phone_code_hash: String,
        session: String,
    },
    Password {
        api_id: i32,
        api_hash: String,
        session: String,
    },
}

fn pending(stage: &Stage, kind: &str, message: &str) -> Result<Value, Failure> {
    Ok(json!({
        "status": "pending",
        "state": serde_json::to_string(stage).map_err(other)?,
        "prompt": {"kind": kind, "message": message},
    }))
}

fn ask(stage: &Stage, retry: Option<&str>) -> Result<Value, Failure> {
    let (kind, message) = match stage {
        Stage::ApiId => (
            "text",
            "API ID from my.telegram.org → API development tools",
        ),
        Stage::ApiHash { .. } => ("password", "API hash from the same page"),
        Stage::Phone { .. } => (
            "text",
            "Phone number in international format, e.g. +14155550123",
        ),
        Stage::Code { .. } => ("text", "The login code Telegram sent you"),
        Stage::Password { .. } => ("password", "Your two-step verification password"),
    };
    match retry {
        Some(problem) => pending(stage, kind, &format!("{problem} {message}")),
        None => pending(stage, kind, message),
    }
}

/// Starts a login, reusing saved app credentials.
pub fn auth_begin(params: &Value) -> Result<Value, Failure> {
    let api_id = secret(params, API_ID).and_then(|id| id.trim().parse().ok());
    match (api_id, secret(params, API_HASH)) {
        (Some(api_id), Some(api_hash)) => ask(
            &Stage::Phone {
                api_id,
                api_hash: api_hash.to_owned(),
            },
            None,
        ),
        _ => ask(&Stage::ApiId, None),
    }
}

pub async fn auth_step(params: &Value) -> Result<Value, Failure> {
    let state = params
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let login: Stage =
        serde_json::from_str(state).map_err(|_| Failure::other("unknown login state"))?;
    let input = params
        .get("input")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    match login {
        Stage::ApiId => match input.parse::<i32>() {
            Ok(api_id) if api_id > 0 => ask(&Stage::ApiHash { api_id }, None),
            _ => ask(&Stage::ApiId, Some("That is not a number.")),
        },
        Stage::ApiHash { api_id } => {
            if input.len() == 32 && input.chars().all(|c| c.is_ascii_hexdigit()) {
                ask(
                    &Stage::Phone {
                        api_id,
                        api_hash: input.to_owned(),
                    },
                    None,
                )
            } else {
                ask(
                    &Stage::ApiHash { api_id },
                    Some("The API hash is 32 letters and digits."),
                )
            }
        }
        Stage::Phone { api_id, api_hash } => send_code(api_id, api_hash, input).await,
        Stage::Code {
            api_id,
            api_hash,
            phone,
            phone_code_hash,
            session,
        } => sign_in(api_id, api_hash, phone, phone_code_hash, session, input).await,
        Stage::Password {
            api_id,
            api_hash,
            session,
        } => check_password(api_id, api_hash, session, input).await,
    }
}

async fn send_code(api_id: i32, api_hash: String, phone: &str) -> Result<Value, Failure> {
    let phone: String = phone
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '+')
        .collect();
    if phone.len() < 6 {
        return ask(
            &Stage::Phone { api_id, api_hash },
            Some("That does not look like a phone number."),
        );
    }
    let connection = Connection::open(api_id, None)?;
    let request = tl::functions::auth::SendCode {
        phone_number: phone.clone(),
        api_id,
        api_hash: api_hash.clone(),
        settings: tl::types::CodeSettings {
            allow_flashcall: false,
            current_number: false,
            allow_app_hash: false,
            allow_missed_call: false,
            allow_firebase: false,
            unknown_number: false,
            logout_tokens: None,
            token: None,
            app_sandbox: None,
        }
        .into(),
    };
    let sent = match connection.client.invoke(&request).await {
        // The number lives on another data center: move there and ask again.
        Err(InvocationError::Rpc(error)) if error.code == 303 => {
            let dc = i32::try_from(error.value.unwrap_or(2)).unwrap_or(2);
            connection.session.set_home_dc_id(dc).await.map_err(other)?;
            connection.client.invoke(&request).await
        }
        other => other,
    };
    let phone_code_hash = match sent {
        Ok(tl::enums::auth::SentCode::Code(code)) => code.phone_code_hash,
        Ok(_) => {
            return Err(Failure::other(
                "Telegram answered the login in an unsupported way",
            ));
        }
        Err(InvocationError::Rpc(error)) if error.name.starts_with("PHONE_NUMBER") => {
            return ask(
                &Stage::Phone { api_id, api_hash },
                Some("Telegram does not know that number."),
            );
        }
        Err(InvocationError::Rpc(error)) if error.name.starts_with("API_ID") => {
            return ask(
                &Stage::ApiId,
                Some("Telegram rejected the API ID and hash."),
            );
        }
        Err(error) => return Err(rpc(error)),
    };
    let session = connection.export()?;
    ask(
        &Stage::Code {
            api_id,
            api_hash,
            phone,
            phone_code_hash,
            session,
        },
        None,
    )
}

async fn sign_in(
    api_id: i32,
    api_hash: String,
    phone: String,
    phone_code_hash: String,
    session: String,
    code: &str,
) -> Result<Value, Failure> {
    let connection = Connection::open(api_id, Some(&session))?;
    let request = tl::functions::auth::SignIn {
        phone_number: phone.clone(),
        phone_code_hash: phone_code_hash.clone(),
        phone_code: Some(code.to_owned()),
        email_verification: None,
    };
    match connection.client.invoke(&request).await {
        Ok(tl::enums::auth::Authorization::Authorization(_)) => {
            done(&connection, api_id, &api_hash)
        }
        Ok(tl::enums::auth::Authorization::SignUpRequired(_)) => Ok(failed(
            "This number has no Telegram account. Create one in the Telegram app first.",
        )),
        Err(error) if error.is("SESSION_PASSWORD_NEEDED") => ask(
            &Stage::Password {
                api_id,
                api_hash,
                session,
            },
            None,
        ),
        Err(error) if error.is("PHONE_CODE_EXPIRED") => {
            Ok(failed("The code expired. Start the sign-in again."))
        }
        Err(error) if error.is("PHONE_CODE_*") => ask(
            &Stage::Code {
                api_id,
                api_hash,
                phone,
                phone_code_hash,
                session,
            },
            Some("That code is wrong."),
        ),
        Err(error) => Err(rpc(error)),
    }
}

async fn check_password(
    api_id: i32,
    api_hash: String,
    session: String,
    password: &str,
) -> Result<Value, Failure> {
    let connection = Connection::open(api_id, Some(&session))?;
    let info: tl::types::account::Password = connection
        .client
        .invoke(&tl::functions::account::GetPassword {})
        .await
        .map_err(rpc)?
        .into();
    match connection
        .client
        .check_password(PasswordToken::new(info), password)
        .await
    {
        Ok(_) => done(&connection, api_id, &api_hash),
        Err(SignInError::InvalidPassword(_)) => ask(
            &Stage::Password {
                api_id,
                api_hash,
                session,
            },
            Some("That password is wrong."),
        ),
        Err(SignInError::Other(error)) => Err(rpc(error)),
        Err(error) => Ok(failed(&error.to_string())),
    }
}

fn done(connection: &Connection, api_id: i32, api_hash: &str) -> Result<Value, Failure> {
    Ok(json!({
        "status": "done",
        "save_secrets": {API_ID: api_id.to_string(), API_HASH: api_hash, SESSION: connection.export()?},
    }))
}

fn failed(message: &str) -> Value {
    json!({"status": "failed", "error": message})
}

// MARK: Chats

/// A chat named by the user: `me` (Saved Messages), `@username`, a `t.me/name` link, a private
/// `t.me/c/<id>` link, or a Bot API ID like `-100…`.
#[derive(Debug, PartialEq, Eq)]
pub enum ChatRef {
    SavedMessages,
    Username(String),
    Channel(i64),
}

impl ChatRef {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if text.eq_ignore_ascii_case("me") {
            return Some(Self::SavedMessages);
        }
        let path = text
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .trim_start_matches("t.me/");
        if let Some(rest) = path.strip_prefix("c/") {
            return rest.split('/').next()?.parse().ok().map(Self::Channel);
        }
        if let Some(id) = text.strip_prefix("-100") {
            return id.parse().ok().map(Self::Channel);
        }
        crate::channel_name(text).map(Self::Username)
    }

    /// Whether only a signed-in account can read it.
    pub fn is_private(&self) -> bool {
        matches!(self, Self::Channel(_))
    }
}

async fn resolve(
    client: &Client,
    chat: &ChatRef,
) -> Result<grammers_client::session::types::PeerRef, Failure> {
    match chat {
        // A real ID, not `InputPeerSelf`: grammers needs one to read a send's short reply, and a
        // fresh process has no cached self peer.
        ChatRef::SavedMessages => client
            .get_me()
            .await
            .map_err(rpc)?
            .to_ref()
            .await
            .map_err(other)?
            .ok_or_else(|| Failure::other("cannot open Saved Messages")),
        ChatRef::Username(name) => {
            let peer = client.resolve_username(name).await.map_err(rpc)?;
            let peer = peer.ok_or_else(|| Failure::rejected(format!("@{name} does not exist")))?;
            peer.to_ref()
                .await
                .map_err(other)?
                .ok_or_else(|| Failure::rejected(format!("cannot open @{name}")))
        }
        ChatRef::Channel(id) => {
            // Private channels have no public name; find it among the account's chats.
            let mut dialogs = client.iter_dialogs();
            while let Some(dialog) = dialogs.next().await.map_err(rpc)? {
                let peer = dialog.peer_id();
                if peer.kind() == PeerKind::Channel && peer.bare_id() == Some(*id) {
                    return Ok(dialog.peer_ref());
                }
            }
            Err(Failure::rejected(format!(
                "this account is not in the chat t.me/c/{id}"
            )))
        }
    }
}

// MARK: Source

/// The newest messages of a chat the account can read.
pub async fn fetch(params: &Value, chat: &ChatRef, limit: usize) -> Result<Vec<RawItem>, Failure> {
    let (api_id, session) = signed_in(params)?;
    let connection = Connection::open(api_id, Some(session))?;
    let peer = resolve(&connection.client, chat).await?;
    let mut messages = connection.client.iter_messages(peer).limit(limit);
    let mut items = Vec::new();
    while let Some(message) = messages.next().await.map_err(rpc)? {
        let text = message.text().to_owned();
        if text.trim().is_empty() {
            continue; // photos and files alone cannot be shown without downloading them
        }
        let url = match chat {
            ChatRef::Channel(id) => Some(format!("https://t.me/c/{id}/{}", message.id())),
            ChatRef::Username(name) => Some(format!("https://t.me/{name}/{}", message.id())),
            ChatRef::SavedMessages => None,
        };
        items.push(RawItem {
            external_id: message.id().to_string(),
            url,
            text,
            author: message.post_author().map(|name| Author {
                name: Some(name.to_owned()),
                ..Author::default()
            }),
            published_at: chrono::DateTime::from_timestamp(message.date().as_second(), 0),
            ..RawItem::default()
        });
    }
    Ok(items)
}

// MARK: Publishing

/// Sends one post. `html` is Telegram HTML; with `image_url` the post is a photo with `caption`,
/// falling back to `html` alone when Telegram cannot use the image.
pub async fn send(params: &Value) -> Result<Value, Failure> {
    let (api_id, session) = signed_in(params)?;
    let chat_text = params
        .get("chat")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let chat = ChatRef::parse(chat_text).ok_or_else(|| {
        Failure::rejected(format!(
            "`{chat_text}` is not a chat: use me, @name or t.me/c/<id>"
        ))
    })?;
    let text = |key: &str| {
        params
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let connection = Connection::open(api_id, Some(session))?;
    let peer = resolve(&connection.client, &chat).await?;
    if let Some(image) = params
        .get("image_url")
        .and_then(Value::as_str)
        .filter(|url| !url.is_empty())
    {
        let photo = InputMessage::new().html(text("caption")).photo_url(image);
        match Box::pin(connection.client.send_message(peer, photo)).await {
            Ok(_) => return Ok(json!({})),
            // Telegram could not fetch or use the image: post the text alone.
            Err(InvocationError::Rpc(error)) if error.code == 400 => {}
            Err(error) => return Err(send_error(error)),
        }
    }
    let message = InputMessage::new().html(text("html")).link_preview(true);
    Box::pin(connection.client.send_message(peer, message))
        .await
        .map_err(send_error)?;
    Ok(json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_chat_references() {
        assert_eq!(ChatRef::parse("me"), Some(ChatRef::SavedMessages));
        assert_eq!(
            ChatRef::parse("https://t.me/c/1234567/89"),
            Some(ChatRef::Channel(1_234_567))
        );
        assert_eq!(
            ChatRef::parse("-1001234567"),
            Some(ChatRef::Channel(1_234_567))
        );
        assert_eq!(
            ChatRef::parse("@durov"),
            Some(ChatRef::Username("durov".into()))
        );
        assert_eq!(ChatRef::parse("not a chat!"), None);
        assert!(ChatRef::parse("t.me/c/1/2").unwrap().is_private());
    }

    #[test]
    fn login_starts_with_saved_credentials_and_validates_input() {
        let fresh = auth_begin(&json!({"secrets": {}})).unwrap();
        assert!(fresh["state"].as_str().unwrap().contains("api_id"));

        let saved =
            auth_begin(&json!({"secrets": {"api_id": "12345", "api_hash": "abc"}})).unwrap();
        assert!(saved["state"].as_str().unwrap().contains("phone"));

        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let wrong = runtime
            .block_on(auth_step(
                &json!({"state": r#"{"stage":"api_id"}"#, "input": "abc"}),
            ))
            .unwrap();
        assert!(
            wrong["prompt"]["message"]
                .as_str()
                .unwrap()
                .starts_with("That is not a number.")
        );
        let hash = runtime
            .block_on(auth_step(&json!({"state": r#"{"stage":"api_hash","api_id":5}"#, "input": "0123456789abcdef0123456789abcdef"})))
            .unwrap();
        assert!(hash["state"].as_str().unwrap().contains("phone"));
    }

    #[test]
    fn requests_without_a_session_ask_to_sign_in() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let error = runtime
            .block_on(send(&json!({"chat": "me", "html": "hi", "secrets": {}})))
            .unwrap_err();
        assert_eq!(error.code, crate::AUTH_REQUIRED);
    }

    #[test]
    fn a_stored_session_round_trips() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let connection = Connection::open(1, None).unwrap();
            connection.session.set_home_dc_id(4).await.unwrap();
            let exported = connection.export().unwrap();
            let reopened = Connection::open(1, Some(&exported)).unwrap();
            assert_eq!(reopened.session.home_dc_id().unwrap(), 4);
            assert_eq!(reopened.export().unwrap(), exported);
        });
    }
}
