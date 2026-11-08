//#region src/utils/lineAnnotationIdentity.ts
const lineAnnotationSources = /* @__PURE__ */ new WeakMap();
/**
* Resolve a possibly-remapped annotation back to the original object it
* descends from. Annotations that were never cloned resolve to themselves.
*/
function getLineAnnotationSource(annotation) {
	const source = lineAnnotationSources.get(annotation);
	return source == null ? annotation : source;
}
function recordLineAnnotationSource(moved, annotation) {
	lineAnnotationSources.set(moved, annotation);
}
//#endregion
export { getLineAnnotationSource, recordLineAnnotationSource };

//# sourceMappingURL=lineAnnotationIdentity.js.map