import { FileContents, LineAnnotation } from "../../types.js";
import { GetHoveredLineResult } from "../../managers/InteractionManager.js";
import { FileProps } from "../types.js";
import { ReactNode } from "react";
//#region src/react/utils/renderFileChildren.d.ts
interface RenderFileChildrenProps<LAnnotation, Caret> {
  file: FileContents;
  renderCustomHeader: FileProps<LAnnotation, Caret>['renderCustomHeader'];
  renderHeaderPrefix: FileProps<LAnnotation, Caret>['renderHeaderPrefix'];
  renderHeaderFilenameSuffix?: FileProps<LAnnotation, Caret>['renderHeaderFilenameSuffix'];
  renderHeaderMetadata: FileProps<LAnnotation, Caret>['renderHeaderMetadata'];
  renderAnnotation: FileProps<LAnnotation, Caret>['renderAnnotation'];
  lineAnnotations: FileProps<LAnnotation, Caret>['lineAnnotations'];
  renderGutterUtility: FileProps<LAnnotation, Caret>['renderGutterUtility'];
  getHoveredLine(): GetHoveredLineResult<'file'> | undefined;
  getAnnotationSlotName?(annotation: LineAnnotation<LAnnotation>): string;
}
declare function renderFileChildren<LAnnotation, Caret>({ file, renderCustomHeader, renderHeaderPrefix, renderHeaderFilenameSuffix, renderHeaderMetadata, renderAnnotation, lineAnnotations, renderGutterUtility, getHoveredLine, getAnnotationSlotName }: RenderFileChildrenProps<LAnnotation, Caret>): ReactNode;
//#endregion
export { renderFileChildren };
//# sourceMappingURL=renderFileChildren.d.ts.map