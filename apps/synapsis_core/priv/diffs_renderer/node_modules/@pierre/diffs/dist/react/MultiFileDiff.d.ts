import { DiffFileInput, FileContents } from "../types.js";
import { DiffBasePropsReact } from "./types.js";
//#region src/react/MultiFileDiff.d.ts
interface MultiFileDiffBaseProps<LAnnotation, Caret> extends DiffBasePropsReact<LAnnotation, Caret> {
  disableWorkerPool?: boolean;
}
type MultiFileDiffProps<LAnnotation, Caret> = MultiFileDiffBaseProps<LAnnotation, Caret> & DiffFileInput;
declare function MultiFileDiff<LAnnotation = undefined, Caret = undefined>({ oldFile, newFile, options, editorOptions, editStateKey, metrics, lineAnnotations, selectedLines, className, style, prerenderedHTML, renderAnnotation, renderCustomHeader, renderHeaderPrefix, renderHeaderFilenameSuffix, renderHeaderMetadata, renderGutterUtility, disableWorkerPool, edit, onEditChange, onEditComplete }: MultiFileDiffProps<LAnnotation, Caret>): React.JSX.Element;
//#endregion
export { type FileContents, MultiFileDiff, MultiFileDiffProps };
//# sourceMappingURL=MultiFileDiff.d.ts.map