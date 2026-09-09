mod bridge;

use bridge::{Bridge, Request, Response};
use tauri::Manager;

#[tauri::command]
async fn dashboard_request(
    window: tauri::WebviewWindow,
    bridge: tauri::State<'_, Bridge>,
    request: Request,
) -> Result<Response, String> {
    if window.label() != "main" {
        return Err("Unknown dashboard window".into());
    }
    let bridge = bridge.inner().clone();
    tauri::async_runtime::spawn_blocking(move || bridge.request(request))
        .await
        .map_err(|error| error.to_string())?
}

fn main() {
    if !std::env::args().any(|arg| arg == "--swift-host") {
        eprintln!("Launch this window through ccusage-gauge dashboard or the menu-bar app.");
        std::process::exit(2);
    }
    tauri::Builder::default()
        .setup(|app| {
            app.manage(Bridge::start(app.handle().clone()));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![dashboard_request])
        .run(tauri::generate_context!())
        .expect("Unable to run the dashboard window");
}
