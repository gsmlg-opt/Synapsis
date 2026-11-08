import { DiffLineAnnotation, FileDiffMetadata } from "../../types.js";
import { GetHoveredLineResult } from "../../managers/InteractionManager.js";
import { MergeConflictDiffAction } from "../../utils/parseMergeConflictDiffFromFile.js";
import { DiffBasePropsReact } from "../types.js";
import { ReactNode } from "react";
//#region src/react/utils/renderDiffChildren.d.ts
interface RenderDiffChildrenProps<LAnnotation, Caret, T> {
  fileDiff: FileDiffMetadata;
  actions?: (MergeConflictDiffAction | undefined)[];
  renderCustomHeader: DiffBasePropsReact<LAnnotation, Caret>['renderCustomHeader'];
  renderHeaderPrefix: DiffBasePropsReact<LAnnotation, Caret>['renderHeaderPrefix'];
  renderHeaderFilenameSuffix?: DiffBasePropsReact<LAnnotation, Caret>['renderHeaderFilenameSuffix'];
  renderHeaderMetadata: DiffBasePropsReact<LAnnotation, Caret>['renderHeaderMetadata'];
  renderAnnotation: DiffBasePropsReact<LAnnotation, Caret>['renderAnnotation'];
  renderGutterUtility: DiffBasePropsReact<LAnnotation, Caret>['renderGutterUtility'];
  renderMergeConflictUtility?(action: MergeConflictDiffAction, getInstance: () => T | undefined): ReactNode;
  lineAnnotations: DiffBasePropsReact<LAnnotation, Caret>['lineAnnotations'];
  getHoveredLine(): GetHoveredLineResult<'diff'> | undefined;
  getInstance?(): T | undefined;
  getAnnotationSlotName?(annotation: DiffLineAnnotation<LAnnotation>): string;
}
declare function renderDiffChildren<LAnnotation, Caret, T>({ fileDiff, actions, renderCustomHeader, renderHeaderPrefix, renderHeaderFilenameSuffix, renderHeaderMetadata, renderAnnotation, renderGutterUtility, renderMergeConflictUtility, lineAnnotations, getHoveredLine, getInstance, getAnnotationSlotName }: RenderDiffChildrenProps<LAnnotation, Caret, T>): ReactNode;
//#endregion
export { renderDiffChildren };
//# sourceMappingURL=renderDiffChildren.d.ts.map