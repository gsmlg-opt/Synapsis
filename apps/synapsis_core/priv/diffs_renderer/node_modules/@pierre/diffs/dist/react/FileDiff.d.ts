import { FileDiffMetadata } from "../types.js";
import { FileDiffEditCompleteEvent } from "../editor/types.js";
import { FileDiffEditChangeHandler, FileDiffEditCompleteHandler } from "../components/FileDiff.js";
import { DiffBasePropsReact } from "./types.js";
//#region src/react/FileDiff.d.ts
interface FileDiffProps<LAnnotation, Caret> extends DiffBasePropsReact<LAnnotation, Caret> {
  fileDiff: FileDiffMetadata;
  disableWorkerPool?: boolean;
}
declare function FileDiff<LAnnotation = undefined, Caret = undefined>({ fileDiff, options, editorOptions, editStateKey, metrics, lineAnnotations, selectedLines, className, style, prerenderedHTML, renderAnnotation, renderCustomHeader, renderHeaderPrefix, renderHeaderFilenameSuffix, renderHeaderMetadata, renderGutterUtility, disableWorkerPool, edit, onEditChange, onEditComplete }: FileDiffProps<LAnnotation, Caret>): React.JSX.Element;
//#endregion
export { FileDiff, type FileDiffEditChangeHandler, type FileDiffEditCompleteEvent, type FileDiffEditCompleteHandler, type FileDiffMetadata, FileDiffProps };
//# sourceMappingURL=FileDiff.d.ts.map