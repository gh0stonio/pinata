export type ConnectionStatus =
	| "booting"
	| "noWorkspace"
	| "loadingAppState"
	| "locatingPi"
	| "startingPi"
	| "restoringSession"
	| "hydratingTimeline"
	| "ready"
	| "streaming"
	| "error";

export type TimelineRole = "user" | "assistant" | "activity";

export type TimelineStatus = "streaming" | "done" | "error";

export interface Workspace {
	id: string;
	name: string;
	path: string;
	activeSessionFile: string | null;
	createdAt: string;
	lastOpenedAt: string;
}

export interface PinataState {
	activeWorkspaceId: string | null;
	workspaces: Workspace[];
}

export interface ConnectionError {
	code: string;
	title: string;
	message: string;
	details: string | null;
}

export interface ModelSummary {
	provider: string | null;
	id: string | null;
	name: string | null;
}

export interface ConnectionSnapshot {
	status: ConnectionStatus;
	message: string | null;
	error: ConnectionError | null;
	piExecutablePath: string | null;
	workspaceId: string | null;
	sessionId: string | null;
	sessionName: string | null;
	sessionFile: string | null;
	model: ModelSummary | null;
	thinkingLevel: string | null;
	toolActivity: string | null;
}

export interface TimelineItem {
	id: string;
	role: TimelineRole;
	text: string;
	status: TimelineStatus;
	createdAt: string;
	toolName: string | null;
	detail: string | null;
}

export interface ExtensionUiRequest {
	id: string;
	method: string;
	title?: string;
	message?: string;
	placeholder?: string;
	prefill?: string;
	options?: string[];
	notifyType?: "info" | "warning" | "error";
	statusKey?: string;
	statusText?: string;
	widgetKey?: string;
	widgetLines?: string[];
	titleText?: string;
	text?: string;
}

export type PinataEvent =
	| { type: "appState"; state: PinataState }
	| { type: "connection"; connection: ConnectionSnapshot }
	| { type: "timelineReset"; items: TimelineItem[] }
	| { type: "timelineItemAdded"; item: TimelineItem }
	| { type: "timelineItemUpdated"; item: TimelineItem }
	| { type: "timelineItemDelta"; id: string; delta: string }
	| { type: "timelineItemStatus"; id: string; status: TimelineStatus }
	| { type: "extensionUiRequest"; request: ExtensionUiRequest }
	| { type: "notice"; message: string };

export interface ExtensionUiResponse {
	type?: "extension_ui_response";
	id: string;
	value?: string;
	confirmed?: boolean;
	cancelled?: boolean;
}
