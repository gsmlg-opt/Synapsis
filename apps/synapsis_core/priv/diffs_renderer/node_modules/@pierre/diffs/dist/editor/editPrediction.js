//#region src/editor/editPrediction.ts
const EDITABLE_TOKENS = 350;
const CONTEXT_TOKENS = 150;
const MAX_EDITABLE_TOKENS = 512;
const MAX_CONTEXT_TOKENS = 662;
const MAX_REQUEST_BYTES = 131072;
const MAX_CAPTURE_BYTES = 6144;
const COALESCE_MS = 1e3;
const COALESCE_LINES = 8;
const DIFF_CONTEXT_LINES = 3;
const CAPTURE_CONTEXT_OPTIONS = [11, DIFF_CONTEXT_LINES];
const textEncoder = new TextEncoder();
function lineStarts(text) {
	const starts = [0];
	for (let index = 0; index < text.length; index++) {
		if (text.charCodeAt(index) === 13 && text.charCodeAt(index + 1) === 10) index++;
		if (text.charCodeAt(index) === 10 || text.charCodeAt(index) === 13) starts.push(index + 1);
	}
	return starts;
}
function diffLineCount(text, starts) {
	if (text.length === 0) return 0;
	return starts.at(-1) === text.length ? starts.length - 1 : starts.length;
}
function lineEnd(text, starts, line) {
	const next = starts[line + 1];
	return next === void 0 ? text.length : next - (text.charCodeAt(next - 1) === 10 && text.charCodeAt(next - 2) === 13 ? 2 : 1);
}
function linesEqual(left, leftStarts, leftLine, right, rightStarts, rightLine) {
	const leftStart = leftStarts[leftLine];
	const rightStart = rightStarts[rightLine];
	const length = lineEnd(left, leftStarts, leftLine) - leftStart;
	if (length !== lineEnd(right, rightStarts, rightLine) - rightStart) return false;
	for (let index = 0; index < length; index++) if (left.charCodeAt(leftStart + index) !== right.charCodeAt(rightStart + index)) return false;
	return true;
}
function lineDiffBounds(oldText, oldStarts, newText, newStarts) {
	const oldLineCount = diffLineCount(oldText, oldStarts);
	const newLineCount = diffLineCount(newText, newStarts);
	let prefixLines = 0;
	while (prefixLines < oldLineCount && prefixLines < newLineCount) {
		if (!linesEqual(oldText, oldStarts, prefixLines, newText, newStarts, prefixLines)) break;
		prefixLines++;
	}
	let suffixLines = 0;
	while (suffixLines < oldLineCount - prefixLines && suffixLines < newLineCount - prefixLines) {
		if (!linesEqual(oldText, oldStarts, oldLineCount - 1 - suffixLines, newText, newStarts, newLineCount - 1 - suffixLines)) break;
		suffixLines++;
	}
	return {
		oldLineCount,
		newLineCount,
		prefixLines,
		suffixLines
	};
}
function formatEditHunk(path, oldText, newText, lineOffset = 0) {
	if (oldText === newText) return;
	const oldStarts = lineStarts(oldText);
	const newStarts = lineStarts(newText);
	const bounds = lineDiffBounds(oldText, oldStarts, newText, newStarts);
	if (bounds.prefixLines === bounds.oldLineCount && bounds.prefixLines === bounds.newLineCount) return;
	const oldChangedEnd = bounds.oldLineCount - bounds.suffixLines;
	const newChangedEnd = bounds.newLineCount - bounds.suffixLines;
	const oldChanged = oldText.slice(oldStarts[bounds.prefixLines] ?? oldText.length, oldStarts[oldChangedEnd] ?? oldText.length);
	const newChanged = newText.slice(newStarts[bounds.prefixLines] ?? newText.length, newStarts[newChangedEnd] ?? newText.length);
	if (textEncoder.encode(oldChanged).byteLength > MAX_CAPTURE_BYTES || textEncoder.encode(newChanged).byteLength > MAX_CAPTURE_BYTES) return;
	const start = Math.max(0, bounds.prefixLines - DIFF_CONTEXT_LINES);
	const oldEnd = Math.min(bounds.oldLineCount, oldChangedEnd + DIFF_CONTEXT_LINES);
	const newEnd = Math.min(bounds.newLineCount, newChangedEnd + DIFF_CONTEXT_LINES);
	const oldCount = oldEnd - start;
	const newCount = newEnd - start;
	const line = start + lineOffset;
	const output = [
		`--- a/${path}`,
		`+++ b/${path}`,
		`@@ -${oldCount === 0 ? line : line + 1},${oldCount} +${newCount === 0 ? line : line + 1},${newCount} @@`
	];
	for (let line = start; line < bounds.prefixLines; line++) output.push(` ${oldText.slice(oldStarts[line], lineEnd(oldText, oldStarts, line))}`);
	for (let line = bounds.prefixLines; line < oldChangedEnd; line++) output.push(`-${oldText.slice(oldStarts[line], lineEnd(oldText, oldStarts, line))}`);
	for (let line = bounds.prefixLines; line < newChangedEnd; line++) output.push(`+${newText.slice(newStarts[line], lineEnd(newText, newStarts, line))}`);
	for (let line = oldChangedEnd; line < oldEnd; line++) output.push(` ${oldText.slice(oldStarts[line], lineEnd(oldText, oldStarts, line))}`);
	const hunk = output.join("\n");
	return textEncoder.encode(hunk).byteLength <= MAX_CAPTURE_BYTES ? {
		hunk,
		bounds
	} : void 0;
}
function applyEditsToSlice(text, sliceStart, edits) {
	const chunks = [];
	let offset = 0;
	for (const edit of edits) {
		const start = edit.start - sliceStart;
		const end = edit.end - sliceStart;
		if (start < offset || end < start || end > text.length) return;
		chunks.push(text.slice(offset, start), edit.text);
		offset = end;
	}
	chunks.push(text.slice(offset));
	return chunks.join("");
}
function captureEditPredictionTransaction(document, transaction) {
	const inverseEdits = transaction.inverseEdits;
	if (inverseEdits.length === 0) return;
	let changedStart = inverseEdits[0].start;
	let changedEnd = inverseEdits[0].end;
	for (let index = 1; index < inverseEdits.length; index++) {
		changedStart = Math.min(changedStart, inverseEdits[index].start);
		changedEnd = Math.max(changedEnd, inverseEdits[index].end);
	}
	const [startPosition, endPosition] = document.positionsAt([changedStart, changedEnd]);
	for (const contextLines of CAPTURE_CONTEXT_OPTIONS) {
		const startLine = Math.max(0, startPosition.line - contextLines);
		const endLine = Math.min(document.lineCount - 1, endPosition.line + contextLines);
		const afterStart = document.offsetAt({
			line: startLine,
			character: 0
		});
		const afterEnd = endLine + 1 < document.lineCount ? document.offsetAt({
			line: endLine + 1,
			character: 0
		}) : document.offsetAt({
			line: endLine,
			character: document.getLineLength(endLine)
		});
		if (afterEnd - afterStart > MAX_CAPTURE_BYTES) continue;
		const afterText = document.getTextSlice(afterStart, afterEnd);
		if (textEncoder.encode(afterText).byteLength > MAX_CAPTURE_BYTES) continue;
		const beforeText = applyEditsToSlice(afterText, afterStart, inverseEdits);
		if (beforeText === void 0 || beforeText.length > MAX_CAPTURE_BYTES || textEncoder.encode(beforeText).byteLength > MAX_CAPTURE_BYTES) continue;
		return {
			beforeText,
			afterText,
			startOffset: afterStart,
			startLine,
			bounds: lineDiffBounds(beforeText, lineStarts(beforeText), afterText, lineStarts(afterText))
		};
	}
}
function recordEditPrediction(history, path, document, transaction, source, at = Date.now()) {
	const kept = history.slice(-10);
	const fragment = captureEditPredictionTransaction(document, transaction);
	if (fragment === void 0) {
		const previous = kept.at(-1);
		if (previous?.fragment !== void 0) kept[kept.length - 1] = {
			...previous,
			fragment: void 0
		};
		return kept;
	}
	if (fragment.beforeText === fragment.afterText) return kept;
	const changedStartLine = fragment.startLine + fragment.bounds.prefixLines;
	const beforeChangedEndLine = fragment.startLine + fragment.bounds.oldLineCount - fragment.bounds.suffixLines;
	const last = kept.at(-1);
	const gap = last !== void 0 && changedStartLine > last.end ? changedStartLine - last.end : last !== void 0 && last.start > beforeChangedEndLine ? last.start - beforeChangedEndLine : 0;
	if (last !== void 0 && last.fragment !== void 0 && last.path === path && last.source === source && at - last.at < COALESCE_MS && gap <= COALESCE_LINES) {
		const previous = last.fragment;
		const beforeEnd = fragment.startOffset + fragment.beforeText.length;
		const overlapStart = Math.max(previous.currentStart, fragment.startOffset);
		const overlapEnd = Math.min(previous.currentEnd, beforeEnd);
		if (overlapStart <= overlapEnd && previous.currentText.slice(overlapStart - previous.currentStart, overlapEnd - previous.currentStart) === fragment.beforeText.slice(overlapStart - fragment.startOffset, overlapEnd - fragment.startOffset)) {
			const unionStart = Math.min(previous.currentStart, fragment.startOffset);
			const currentText = previous.currentStart <= fragment.startOffset ? previous.currentText + fragment.beforeText.slice(Math.max(0, previous.currentEnd - fragment.startOffset)) : fragment.beforeText + previous.currentText.slice(Math.max(0, beforeEnd - previous.currentStart));
			const prefix = currentText.slice(0, previous.currentStart - unionStart);
			const suffix = currentText.slice(previous.currentEnd - unionStart);
			const baseText = prefix + previous.baseText + suffix;
			const nextText = applyEditsToSlice(currentText, unionStart, transaction.appliedEdits);
			const startLine = previous.currentStart <= fragment.startOffset ? previous.startLine : fragment.startLine;
			if (nextText !== void 0 && baseText.length <= MAX_CAPTURE_BYTES && nextText.length <= MAX_CAPTURE_BYTES && textEncoder.encode(baseText).byteLength <= MAX_CAPTURE_BYTES && textEncoder.encode(nextText).byteLength <= MAX_CAPTURE_BYTES) {
				if (baseText === nextText) {
					kept.pop();
					return kept;
				}
				const formatted = formatEditHunk(path, baseText, nextText, startLine);
				if (formatted !== void 0) {
					kept[kept.length - 1] = {
						path,
						hunk: formatted.hunk,
						start: startLine + formatted.bounds.prefixLines,
						end: startLine + formatted.bounds.newLineCount - formatted.bounds.suffixLines,
						at,
						source,
						fragment: {
							baseText,
							currentText: nextText,
							currentStart: unionStart,
							currentEnd: unionStart + nextText.length,
							startLine
						}
					};
					return kept;
				}
			}
		}
	}
	const previous = kept.at(-1);
	if (previous?.fragment !== void 0) kept[kept.length - 1] = {
		...previous,
		fragment: void 0
	};
	const formatted = formatEditHunk(path, fragment.beforeText, fragment.afterText, fragment.startLine);
	if (formatted === void 0) return kept;
	kept.push({
		path,
		hunk: formatted.hunk,
		start: changedStartLine,
		end: fragment.startLine + fragment.bounds.newLineCount - fragment.bounds.suffixLines,
		at,
		source,
		fragment: {
			baseText: fragment.beforeText,
			currentText: fragment.afterText,
			currentStart: fragment.startOffset,
			currentEnd: fragment.startOffset + fragment.afterText.length,
			startLine: fragment.startLine
		}
	});
	return kept.slice(-10);
}
function expandLinewise(lineCount, costForLine, canExpandTo, first, last, remaining) {
	while (remaining > 0 && (first > 0 || last < lineCount - 1)) {
		let expanded = false;
		if (first > 0 && canExpandTo(first - 1)) {
			const cost = costForLine(first - 1);
			if (cost <= remaining) {
				first--;
				remaining -= cost;
				expanded = true;
			}
		}
		if (last < lineCount - 1 && canExpandTo(last + 1)) {
			const cost = costForLine(last + 1);
			if (cost <= remaining) {
				last++;
				remaining -= cost;
				expanded = true;
			}
		}
		if (!expanded) break;
	}
	return {
		first,
		last
	};
}
function buildEditPredictionRequest(path, document, cursorOffset, history, isLineEditable) {
	if (document.lineCount <= 0) return;
	const lastLine = document.lineCount - 1;
	const documentLength = document.offsetAt({
		line: lastLine,
		character: document.getLineLength(lastLine)
	});
	let cursor = Math.max(0, Math.min(Number.isFinite(cursorOffset) ? Math.trunc(cursorOffset) : 0, documentLength));
	const previous = document.charAt(cursor - 1).charCodeAt(0);
	const next = document.charAt(cursor).charCodeAt(0);
	if (cursor > 0 && cursor < documentLength && (previous === 13 && next === 10 || previous >= 55296 && previous <= 56319 && next >= 56320 && next <= 57343)) cursor--;
	const cursorLine = document.positionAt(cursor).line;
	const editableLines = /* @__PURE__ */ new Map();
	const canEdit = (line) => {
		if (line < 0 || line >= document.lineCount) return false;
		let editable = editableLines.get(line);
		if (editable == null) {
			editable = isLineEditable(line);
			editableLines.set(line, editable);
		}
		return editable;
	};
	if (!canEdit(cursorLine)) return;
	const tokenCosts = /* @__PURE__ */ new Map();
	const costForLine = (line) => {
		const cached = tokenCosts.get(line);
		if (cached !== void 0) return cached;
		const lineLength = document.getLineLength(line);
		if (Math.floor(lineLength / 3) > MAX_CONTEXT_TOKENS) {
			const cost = 663;
			tokenCosts.set(line, cost);
			return cost;
		}
		const cost = Math.max(1, Math.floor(textEncoder.encode(document.getLineText(line)).byteLength / 3));
		tokenCosts.set(line, cost);
		return cost;
	};
	let editableFirst = cursorLine;
	let editableLast = cursorLine;
	let remaining = Math.max(0, Math.floor(EDITABLE_TOKENS * 3 / 4) - costForLine(cursorLine));
	while (remaining > 0 && (canEdit(editableFirst - 1) || canEdit(editableLast + 1))) {
		if (canEdit(editableLast + 1)) {
			const cost = costForLine(editableLast + 1);
			if (cost > remaining) break;
			editableLast++;
			remaining -= cost;
		}
		if (canEdit(editableFirst - 1) && remaining > 0) {
			const cost = costForLine(editableFirst - 1);
			if (cost > remaining) break;
			editableFirst--;
			remaining -= cost;
		}
	}
	remaining += 88;
	({first: editableFirst, last: editableLast} = expandLinewise(document.lineCount, costForLine, canEdit, editableFirst, editableLast, remaining));
	let contextFirst = editableFirst;
	let contextLast = editableLast;
	({first: contextFirst, last: contextLast} = expandLinewise(document.lineCount, costForLine, () => true, contextFirst, contextLast, CONTEXT_TOKENS));
	let editableTokens = 0;
	for (let line = editableFirst; line <= editableLast; line++) editableTokens += costForLine(line);
	let contextTokens = 0;
	for (let line = contextFirst; line <= contextLast; line++) contextTokens += costForLine(line);
	if (editableTokens > MAX_EDITABLE_TOKENS || contextTokens > MAX_CONTEXT_TOKENS) return;
	const contextStart = document.offsetAt({
		line: contextFirst,
		character: 0
	});
	const contextEnd = document.offsetAt({
		line: contextLast,
		character: document.getLineLength(contextLast)
	});
	const excerptText = document.getTextSlice(contextStart, contextEnd);
	const request = {
		path,
		version: document.version,
		eol: document.eol,
		excerptText,
		excerptStartLine: contextFirst,
		cursorOffsetInExcerpt: cursor - contextStart,
		editableRange: {
			start: document.offsetAt({
				line: editableFirst,
				character: 0
			}) - contextStart,
			end: document.offsetAt({
				line: editableLast,
				character: document.getLineLength(editableLast)
			}) - contextStart
		},
		editHistory: history.slice(-10).map(({ hunk, source }) => ({
			diff: hunk,
			source
		}))
	};
	return textEncoder.encode(JSON.stringify(request)).byteLength <= MAX_REQUEST_BYTES ? request : void 0;
}
function matchesEditPredictionPattern(path, pattern) {
	if (typeof pattern !== "string") return new RegExp(pattern.source, pattern.flags).test(path);
	pattern = pattern.replaceAll("\\", "/");
	let source = "^";
	for (let index = 0; index < pattern.length; index++) {
		const character = pattern[index];
		if (character === "*") {
			if (pattern[index + 1] === "*") {
				index++;
				if (pattern[index + 1] === "/") {
					index++;
					source += "(?:.*/)?";
				} else source += ".*";
			} else source += "[^/]*";
		} else if (character === "?") source += "[^/]";
		else source += /[\\^$.*+?()[\]{}|]/.test(character) ? `\\${character}` : character;
	}
	return new RegExp(`${source}$`).test(path);
}
//#endregion
export { buildEditPredictionRequest, matchesEditPredictionPattern, recordEditPrediction };

//# sourceMappingURL=editPrediction.js.map