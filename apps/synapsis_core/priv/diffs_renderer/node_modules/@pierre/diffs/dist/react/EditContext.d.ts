import { EditorFactory } from "../editor/types.js";
import "../edit/index.js";
import { Context, PropsWithChildren } from "react";
//#region src/react/EditContext.d.ts
interface EditProviderProps<LAnnotation, Caret> {
  /** Combines shared defaults with the supplied per-surface options. */
  createEditor: EditorFactory<LAnnotation, Caret>;
}
declare const EditContext: Context<EditorFactory<any, any> | undefined>;
declare function EditProvider<LAnnotation = undefined, Caret = undefined>({ children, createEditor }: PropsWithChildren<EditProviderProps<LAnnotation, Caret>>): React.JSX.Element;
declare function useCreateEditor<LAnnotation, Caret>(): EditorFactory<LAnnotation, Caret> | undefined;
//#endregion
export { EditContext, EditProvider, EditProviderProps, type EditorFactory, useCreateEditor };
//# sourceMappingURL=EditContext.d.ts.map