use tauri::{
    menu::{AboutMetadata, Menu, MenuItemBuilder, PredefinedMenuItem, Submenu},
    Emitter, Listener,
};

mod app_state;
mod repository;
mod terminal;

const OPEN_SETTINGS_MENU_ID: &str = "open-settings";
const OPEN_SETTINGS_EVENT: &str = "pinata://open-settings";

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    if let Err(error) = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(terminal::TerminalState::default())
        .invoke_handler(tauri::generate_handler![
            repository::create_task_repo_worktree,
            repository::delete_task_repo_worktree,
            repository::inspect_repository,
            app_state::load_app_state,
            app_state::save_app_state,
            terminal::terminal_attach,
            terminal::terminal_detach,
            terminal::terminal_ensure_session,
            terminal::terminal_kill_session,
            terminal::terminal_resize
        ])
        .setup(|app| {
            let handle = app.handle();
            let terminal_handle = handle.clone();
            app.listen_any(terminal::TERMINAL_INPUT_EVENT, move |event| {
                terminal::handle_terminal_input_event(terminal_handle.clone(), event);
            });
            let package_info = handle.package_info();
            let about_metadata = AboutMetadata {
                name: Some(package_info.name.clone()),
                version: Some(package_info.version.to_string()),
                ..Default::default()
            };
            let settings = MenuItemBuilder::with_id(OPEN_SETTINGS_MENU_ID, "Settings...")
                .accelerator("CmdOrCtrl+,")
                .build(handle)?;

            let app_menu = Submenu::with_items(
                handle,
                package_info.name.clone(),
                true,
                &[
                    &PredefinedMenuItem::about(handle, None, Some(about_metadata))?,
                    &PredefinedMenuItem::separator(handle)?,
                    &settings,
                    &PredefinedMenuItem::separator(handle)?,
                    &PredefinedMenuItem::services(handle, None)?,
                    &PredefinedMenuItem::separator(handle)?,
                    &PredefinedMenuItem::hide(handle, None)?,
                    &PredefinedMenuItem::hide_others(handle, None)?,
                    &PredefinedMenuItem::separator(handle)?,
                    &PredefinedMenuItem::quit(handle, None)?,
                ],
            )?;
            let edit_menu = Submenu::with_items(
                handle,
                "Edit",
                true,
                &[
                    &PredefinedMenuItem::undo(handle, None)?,
                    &PredefinedMenuItem::redo(handle, None)?,
                    &PredefinedMenuItem::separator(handle)?,
                    &PredefinedMenuItem::cut(handle, None)?,
                    &PredefinedMenuItem::copy(handle, None)?,
                    &PredefinedMenuItem::paste(handle, None)?,
                    &PredefinedMenuItem::select_all(handle, None)?,
                ],
            )?;
            let view_menu = Submenu::with_items(
                handle,
                "View",
                true,
                &[&PredefinedMenuItem::fullscreen(handle, None)?],
            )?;
            let window_menu = Submenu::with_items(
                handle,
                "Window",
                true,
                &[
                    &PredefinedMenuItem::minimize(handle, None)?,
                    &PredefinedMenuItem::maximize(handle, None)?,
                    &PredefinedMenuItem::separator(handle)?,
                    &PredefinedMenuItem::close_window(handle, None)?,
                ],
            )?;
            let menu =
                Menu::with_items(handle, &[&app_menu, &edit_menu, &view_menu, &window_menu])?;

            app.set_menu(menu)?;
            Ok(())
        })
        .on_menu_event(|app, event| {
            if event.id().0 == OPEN_SETTINGS_MENU_ID {
                let _ = app.emit(OPEN_SETTINGS_EVENT, ());
            }
        })
        .run(tauri::generate_context!())
    {
        eprintln!("error while running Tauri application: {error}");
    }
}
