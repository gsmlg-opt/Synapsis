import { FileEditCompleteEvent } from "../editor/types.js";
import { FileEditChangeHandler, FileEditCompleteHandler } from "../components/File.js";
import { FileOptions, FileProps } from "./types.js";
//#region src/react/File.d.ts
declare function File<LAnnotation = undefined, Caret = undefined>({ file, lineAnnotations, selectedLines, options, editorOptions, editStateKey, metrics, className, style, renderAnnotation, renderCustomHeader, renderHeaderPrefix, renderHeaderFilenameSuffix, renderHeaderMetadata, prerenderedHTML, renderGutterUtility, disableWorkerPool, edit, onEditChange, onEditComplete }: FileProps<LAnnotation, Caret>): React.JSX.Element;
//#endregion
export { File, type FileEditChangeHandler, type FileEditCompleteEvent, type FileEditCompleteHandler, type FileOptions };
//# sourceMappingURL=File.d.ts.map