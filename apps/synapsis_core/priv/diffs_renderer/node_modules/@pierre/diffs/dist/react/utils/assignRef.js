//#region src/react/utils/assignRef.ts
function assignRef(ref, value) {
	if (typeof ref === "function") ref(value);
	else if (ref != null) ref.current = value;
}
//#endregion
export { assignRef };

//# sourceMappingURL=assignRef.js.map