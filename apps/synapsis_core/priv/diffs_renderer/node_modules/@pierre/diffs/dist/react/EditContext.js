"use client";
import { useStableCallback } from "./utils/useStableCallback.js";
import { createContext, useContext } from "react";
import { jsx } from "react/jsx-runtime";
//#region src/react/EditContext.tsx
const EditContext = createContext(void 0);
function EditProvider({ children, createEditor }) {
	const stableCreateEditor = useStableCallback((editorType, options, editStateKey) => createEditor(editorType, options, editStateKey));
	return /* @__PURE__ */ jsx(EditContext.Provider, {
		value: stableCreateEditor,
		children
	});
}
function useCreateEditor() {
	return useContext(EditContext);
}
//#endregion
export { EditContext, EditProvider, useCreateEditor };

//# sourceMappingURL=EditContext.js.map