use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    io::{self, BufRead, Write},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    time::Duration,
};

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub path: String,
    pub method: String,
    pub body: Option<String>,
}

impl Request {
    fn validate(&self) -> Result<(), String> {
        if !self.path.starts_with("/api/") || self.path.contains(['\r', '\n', '#']) {
            return Err("Only dashboard API paths are supported".into());
        }
        if !["GET", "POST", "PUT", "PATCH", "DELETE"].contains(&self.method.as_str()) {
            return Err("Unsupported dashboard method".into());
        }
        if self
            .body
            .as_ref()
            .is_some_and(|body| body.len() > 1_048_576)
        {
            return Err("Dashboard request body is too large".into());
        }
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    pub id: u64,
    pub status: u16,
    pub content_type: String,
    pub body: String,
}

#[derive(Clone, Default)]
pub struct Bridge {
    pending: Arc<Mutex<HashMap<u64, mpsc::Sender<Response>>>>,
    sequence: Arc<AtomicU64>,
}

impl Bridge {
    pub fn start(app: tauri::AppHandle) -> Self {
        let bridge = Self::default();
        let reader = bridge.clone();
        std::thread::spawn(move || {
            for line in io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                let Ok(response) = serde_json::from_str::<Response>(&line) else {
                    break;
                };
                if let Some(sender) = reader.pending.lock().unwrap().remove(&response.id) {
                    let _ = sender.send(response);
                }
            }
            reader.pending.lock().unwrap().clear();
            // A window cannot outlive its Swift data owner.
            app.exit(0);
        });
        bridge
    }

    pub fn request(&self, request: Request) -> Result<Response, String> {
        request.validate()?;
        let id = self.sequence.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = mpsc::channel();
        self.pending.lock().unwrap().insert(id, sender);
        let result =
            (|| {
                let mut output = io::stdout().lock();
                serde_json::to_writer(&mut output, &serde_json::json!({
                "id": id, "path": request.path, "method": request.method, "body": request.body
            })).map_err(|error| error.to_string())?;
                output.write_all(b"\n").map_err(|error| error.to_string())?;
                output.flush().map_err(|error| error.to_string())?;
                drop(output);
                receiver
                    .recv_timeout(Duration::from_secs(120))
                    .map_err(|_| "Swift dashboard request timed out or disconnected".to_string())
            })();
        self.pending.lock().unwrap().remove(&id);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restricts_requests_to_dashboard_api() {
        for path in [
            "https://example.com/api/health",
            "/",
            "/api/health\n",
            "/api/health#x",
        ] {
            assert!(Request {
                path: path.into(),
                method: "GET".into(),
                body: None
            }
            .validate()
            .is_err());
        }
        assert!(Request {
            path: "/api/metrics?machine=all".into(),
            method: "GET".into(),
            body: None
        }
        .validate()
        .is_ok());
        assert!(Request {
            path: "/api/cache".into(),
            method: "OPTIONS".into(),
            body: None
        }
        .validate()
        .is_err());
    }
}
