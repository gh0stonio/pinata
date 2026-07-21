use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{
    menu::{AboutMetadata, Menu, MenuItemBuilder, PredefinedMenuItem, Submenu},
    Emitter, Listener, Manager, State,
};

mod app_state;
mod repository;
mod terminal;

const OPEN_SETTINGS_MENU_ID: &str = "open-settings";
const REQUEST_APP_CLOSE_MENU_ID: &str = "request-app-close";
const OPEN_SETTINGS_EVENT: &str = "pinata://open-settings";
const REQUEST_APP_CLOSE_EVENT: &str = "pinata://request-app-close";

#[derive(Default)]
struct AppCloseState {
    confirmed: AtomicBool,
}

#[tauri::command]
fn confirm_app_close(app: tauri::AppHandle, state: State<AppCloseState>) {
    state.confirmed.store(true, Ordering::SeqCst);
    app.exit(0);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppCloseState::default())
        .manage(terminal::TerminalState::default())
        .invoke_handler(tauri::generate_handler![
            confirm_app_close,
            repository::create_task_repo_worktree,
            repository::delete_task_repo_worktree,
            repository::inspect_repository,
            app_state::load_app_state,
            app_state::save_app_state,
            terminal::terminal_attach,
            terminal::terminal_detach,
            terminal::terminal_ensure_session,
            terminal::terminal_kill_session,
            terminal::terminal_resize,
            terminal::terminal_scroll,
            terminal::terminal_cancel_scroll,
            terminal::terminal_clear,
            terminal::terminal_process_status,
            terminal::terminal_shell_name
        ])
        .setup(|app| {
            let handle = app.handle();
            if let Err(error) = app_state::restore_window_layout(handle) {
                eprintln!("failed to restore window layout: {error}");
            }

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
            let quit = MenuItemBuilder::with_id(REQUEST_APP_CLOSE_MENU_ID, "Quit Piñata")
                .accelerator("CmdOrCtrl+Q")
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
                    &quit,
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
            } else if event.id().0 == REQUEST_APP_CLOSE_MENU_ID {
                let _ = app.emit(REQUEST_APP_CLOSE_EVENT, ());
            }
        })
        .build(tauri::generate_context!());

    match app {
        Ok(app) => app.run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                let close_state = app.state::<AppCloseState>();

                if !close_state.confirmed.load(Ordering::SeqCst) {
                    api.prevent_exit();
                    let _ = app.emit(REQUEST_APP_CLOSE_EVENT, ());
                }
            }
        }),
        Err(error) => eprintln!("error while building Tauri application: {error}"),
    }
}
