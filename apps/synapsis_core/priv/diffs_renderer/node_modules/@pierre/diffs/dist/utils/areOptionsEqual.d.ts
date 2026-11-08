import { FileDiffOptions } from "../components/FileDiff.js";
import { CodeViewOptions } from "../components/CodeView.js";
import { FileOptions } from "../react/types.js";
import "../react/index.js";
//#region src/utils/areOptionsEqual.d.ts
type AnyOptions<L, C> = CodeViewOptions<L, C> | FileOptions<L, C> | FileDiffOptions<L, C> | undefined;
declare function areOptionsEqual<LAnnotation, Caret>(optionsA: AnyOptions<LAnnotation, Caret>, optionsB: AnyOptions<LAnnotation, Caret>): boolean;
//#endregion
export { areOptionsEqual };
//# sourceMappingURL=areOptionsEqual.d.ts.map