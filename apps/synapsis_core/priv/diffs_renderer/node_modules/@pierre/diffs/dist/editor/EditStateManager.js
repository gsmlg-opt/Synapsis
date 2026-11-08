import LRUMapPkg from "lru_map";
//#region src/editor/EditStateManager.ts
const DEFAULT_EDIT_STATE_CAPACITY = 100;
/** Owns dormant edit state and active-key exclusion for one editor type. */
var EditStateManagerNamespace = class {
	type;
	#states = new LRUMapPkg.LRUMap(DEFAULT_EDIT_STATE_CAPACITY);
	#sessions = /* @__PURE__ */ new Map();
	constructor(type) {
		this.type = type;
	}
	activate(editStateKey, owner, initialState) {
		const activeSession = this.#sessions.get(editStateKey);
		if (activeSession != null && activeSession.owner !== owner) throw new Error(`Editor: editStateKey "${editStateKey}" is already attached to another editor`);
		if (activeSession != null) {
			if (initialState != null) activeSession.session = initialState;
			return activeSession.session;
		}
		const retainedState = this.#states.delete(editStateKey);
		const emptyState = { type: this.type };
		const state = initialState ?? retainedState ?? emptyState;
		this.#sessions.set(editStateKey, {
			owner,
			session: state
		});
		return state;
	}
	release(editStateKey, owner, discard = false) {
		const activeSession = this.#sessions.get(editStateKey);
		if (activeSession?.owner !== owner) return;
		this.#sessions.delete(editStateKey);
		if (discard) return;
		const retainedState = toManagedEditState(activeSession.session);
		if (retainedState != null) this.#states.set(editStateKey, retainedState);
	}
	get(editStateKey) {
		const activeSession = this.#sessions.get(editStateKey);
		if (activeSession != null) {
			const state = toManagedEditState(activeSession.session);
			if (state == null) return;
			return state;
		}
		return this.#states.find(editStateKey);
	}
	/** Clear dormant state for a key. Omit `parts` to clear everything. */
	clear(editStateKey, parts) {
		if (this.#sessions.has(editStateKey)) return false;
		const state = this.#states.find(editStateKey);
		if (state == null) return false;
		if (parts == null || parts.document === true) this.#states.delete(editStateKey);
		else applyClearEditStateOptions(state, parts);
		return true;
	}
	clearAll() {
		this.#states.clear();
	}
	setCapacity(capacity) {
		if (!Number.isSafeInteger(capacity) || capacity < 1) throw new RangeError("EditStateManager: capacity must be a positive integer");
		while (this.#states.size > capacity) this.#states.shift();
		this.#states.limit = capacity;
	}
};
/** Keeps file and diff edit state in independent persistence domains. */
var EditStateManagerClass = class {
	#files = new EditStateManagerNamespace("file");
	#diffs = new EditStateManagerNamespace("file-diff");
	/** Mark a keyed session as active and return its initial or stored state. */
	activate(type, editStateKey, owner, initialState) {
		return type === "file" ? this.#files.activate(editStateKey, owner, initialState) : this.#diffs.activate(editStateKey, owner, initialState);
	}
	/**
	* Stop tracking this file session as active and store its current state,
	* unless `discard` is true.
	*/
	releaseFile(editStateKey, owner, discard = false) {
		this.#files.release(editStateKey, owner, discard);
	}
	/**
	* Stop tracking this diff session as active and store its current state,
	* unless `discard` is true.
	*/
	releaseFileDiff(editStateKey, owner, discard = false) {
		this.#diffs.release(editStateKey, owner, discard);
	}
	/** Return current state for an active or dormant editing session. */
	get(type, editStateKey) {
		return type === "file" ? this.#files.get(editStateKey) : this.#diffs.get(editStateKey);
	}
	/** Clear a dormant session, returning false when it is active or missing. */
	clear(type, editStateKey, parts) {
		return type === "file" ? this.#files.clear(editStateKey, parts) : this.#diffs.clear(editStateKey, parts);
	}
	/** Clear all dormant sessions without affecting active editors. */
	clearAll() {
		this.#files.clearAll();
		this.#diffs.clearAll();
	}
	setCapacity(capacity) {
		this.#files.setCapacity(capacity);
		this.#diffs.setCapacity(capacity);
	}
};
function cloneEditorViewState(state) {
	return {
		selections: state.selections?.map((selection) => ({
			...selection,
			start: { ...selection.start },
			end: { ...selection.end }
		})),
		view: state.view == null ? void 0 : { ...state.view }
	};
}
function toManagedEditState(session) {
	if (session.document == null || session.fileInfo == null) return;
	if (session.type === "file") {
		session.editor ??= {};
		return session;
	}
	if (session.diffSession == null) return;
	session.editor ??= {};
	return session;
}
function applyClearEditStateOptions(session, parts) {
	if (session == null) return;
	if (parts.history === true) session.document?.clearHistory();
	if (session.editor != null) {
		if (parts.editor === true || parts.selections === true) session.editor.selections = void 0;
		if (parts.editor === true || parts.view === true) session.editor.view = void 0;
	}
}
const EditStateManager = new EditStateManagerClass();
//#endregion
export { EditStateManager, cloneEditorViewState, toManagedEditState };

//# sourceMappingURL=EditStateManager.js.map