import { EditHistoryEntry, EditHistoryState, EditorLineAnnotation, EditorSelection, EditorType, ResolvedTextEdit } from "./types.js";
import { TextDocument } from "./textDocument.js";
//#region src/editor/editStack.d.ts
type EditStackEntry<EType extends EditorType, LAnnotation = unknown> = EditHistoryEntry<EType, LAnnotation>;
/** Options for the edit stack. */
interface EditStackOptions {
  /** The maximum number of entries to keep in the undo stack. */
  maxEntries?: number;
}
/** A stack of edit entries. */
declare class EditStack<EType extends EditorType, LAnnotation = unknown> {
  #private;
  constructor(options?: EditStackOptions);
  get canUndo(): boolean;
  get canRedo(): boolean;
  /** Return an independent, developer-editable history snapshot. */
  getState(): EditHistoryState<EType, LAnnotation>;
  /** Return a live view over this stack without copying its entries. */
  getLiveState(): EditHistoryState<EType, LAnnotation>;
  /** Transfer developer-owned history into an edit stack. */
  static fromState<EType extends EditorType, LAnnotation>(state: EditHistoryState<EType, LAnnotation>): EditStack<EType, LAnnotation>;
  /** Clears both the undo and redo stacks. */
  clear(): void;
  /** Clears the redo stack. */
  clearRedo(): void;
  /** Pushes a new entry onto the undo stack. */
  push(entry: EditStackEntry<EType, LAnnotation>): void;
  /** Sets the selections after the last undo entry. */
  setLastUndoSelectionsAfter(selections: EditorSelection[]): void;
  /** Sets the line annotations after the last undo entry. */
  setLastUndoLineAnnotations(lineAnnotationsBefore: EditorLineAnnotation<EType, LAnnotation>[], lineAnnotationsAfter: EditorLineAnnotation<EType, LAnnotation>[]): void;
  /** Returns the last undo entry, or `undefined` if empty. */
  peekUndo(): EditStackEntry<EType, LAnnotation> | undefined;
  /** Returns the last undo entry only while its coalescing group is open. */
  peekUndoForCoalescing(): EditStackEntry<EType, LAnnotation> | undefined;
  /** Replaces the last undo entry with the given entry. */
  replaceLastUndo(entry: EditStackEntry<EType, LAnnotation>): void;
  /** Moves the latest undo entry to the redo stack and returns it, or `undefined` if empty. */
  popUndoToRedo(): EditStackEntry<EType, LAnnotation> | void;
  /** Moves the latest redo entry back to the undo stack and returns it, or `undefined` if empty. */
  popRedoToUndo(): EditStackEntry<EType, LAnnotation> | void;
}
declare function createEditStackEntry<EType extends EditorType, LAnnotation>(textDocument: TextDocument<EType, LAnnotation>, resolvedEdits: ResolvedTextEdit[], versionBefore: number, versionAfter: number, selectionsBefore?: EditorSelection[], selectionsAfter?: EditorSelection[], lineAnnotationsBefore?: EditorLineAnnotation<EType, LAnnotation>[], lineAnnotationsAfter?: EditorLineAnnotation<EType, LAnnotation>[]): EditStackEntry<EType, LAnnotation>;
/** Determines if the change matches following modes:
 * - 'insert': simple typing
 * - 'backspace': backward delete
 * - 'delete': forward delete
 */
declare function shouldCoalesceEditStackEntry<EType extends EditorType, LAnnotation>(previousEntry: EditStackEntry<EType, LAnnotation> | undefined, nextEntry: EditStackEntry<EType, LAnnotation>): boolean;
/** Coalesce edit stack entries for simple typing and single-character deletes. */
declare function coalesceEditStackEntries<EType extends EditorType, LAnnotation>(previousEntry: EditStackEntry<EType, LAnnotation>, nextEntry: EditStackEntry<EType, LAnnotation>): EditStackEntry<EType, LAnnotation>;
//#endregion
export { EditStack, EditStackEntry, EditStackOptions, coalesceEditStackEntries, createEditStackEntry, shouldCoalesceEditStackEntry };
//# sourceMappingURL=editStack.d.ts.map