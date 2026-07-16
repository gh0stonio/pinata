#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if let Err(error) = tauri::Builder::default()
        .run(tauri::generate_context!())
    {
        eprintln!("error while running Tauri application: {error}");
    }
}
