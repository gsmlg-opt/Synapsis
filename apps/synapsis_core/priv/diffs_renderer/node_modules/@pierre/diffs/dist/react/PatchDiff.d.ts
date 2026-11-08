import { DiffBasePropsReact } from "./types.js";
//#region src/react/PatchDiff.d.ts
interface PatchDiffProps<LAnnotation, Caret> extends DiffBasePropsReact<LAnnotation, Caret> {
  patch: string;
  disableWorkerPool?: boolean;
}
declare function PatchDiff<LAnnotation = undefined, Caret = undefined>({ patch, options, editorOptions, editStateKey, metrics, lineAnnotations, selectedLines, className, style, prerenderedHTML, renderAnnotation, renderCustomHeader, renderHeaderPrefix, renderHeaderFilenameSuffix, renderHeaderMetadata, renderGutterUtility, disableWorkerPool, edit, onEditChange, onEditComplete }: PatchDiffProps<LAnnotation, Caret>): React.JSX.Element;
//#endregion
export { PatchDiff, PatchDiffProps };
//# sourceMappingURL=PatchDiff.d.ts.map