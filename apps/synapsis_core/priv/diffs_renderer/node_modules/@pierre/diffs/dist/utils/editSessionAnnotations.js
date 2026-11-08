import { getLineAnnotationSource } from "./lineAnnotationIdentity.js";
//#region src/utils/editSessionAnnotations.ts
/**
* Creates session state when an editor attaches. The array is kept as-is for
* both `provided` and `current`, and we record each annotation's slot name
* before any edits can move it.
*
* `previousSession` covers a whole new file or diff arriving mid-edit. The
* annotations that come with it describe the new document, so we rebuild the
* session around them — but any annotation the outgoing session already
* named keeps that name, since the caller's content is already rendered into
* a slot with it. Names for annotations that didn't survive the swap are
* simply dropped.
*/
function adoptEditSessionAnnotations(annotations, getName, previousSession) {
	const slotNames = /* @__PURE__ */ new Map();
	for (const annotation of annotations) {
		const source = getLineAnnotationSource(annotation);
		slotNames.set(source, previousSession?.slotNames.get(source) ?? getName(annotation));
	}
	return {
		provided: annotations,
		current: annotations,
		slotNames
	};
}
/**
* Handles the caller passing a brand new annotations array while editing is
* active. We take it exactly as given — line numbers are read against the
* document as currently edited, and there's no merging with what the session
* had — so it replaces both `provided` and `current`. Annotations we've seen
* before keep their recorded slot names; new ones record a name for wherever
* they landed.
*/
function writeEditSessionAnnotations(session, annotations, getName) {
	for (const annotation of annotations) {
		const source = getLineAnnotationSource(annotation);
		if (!session.slotNames.has(source)) session.slotNames.set(source, getName(annotation));
	}
	session.provided = annotations;
	session.current = annotations;
}
/**
* Every slot name an editable component renders resolves through here. With
* no active session this is just the normal position-derived name. During a
* session we return the recorded name instead, and an annotation we've never
* seen records its name the first time anyone asks. That way everything that
* writes slot names — the renderers, the editor, the light-DOM wrappers —
* lands on the same name for the same annotation.
*/
function resolveEditSessionSlotName(session, annotation, getName) {
	if (session == null) return getName(annotation);
	const source = getLineAnnotationSource(annotation);
	let name = session.slotNames.get(source);
	if (name == null) {
		name = getName(annotation);
		session.slotNames.set(source, name);
	}
	return name;
}
//#endregion
export { adoptEditSessionAnnotations, resolveEditSessionSlotName, writeEditSessionAnnotations };

//# sourceMappingURL=editSessionAnnotations.js.map