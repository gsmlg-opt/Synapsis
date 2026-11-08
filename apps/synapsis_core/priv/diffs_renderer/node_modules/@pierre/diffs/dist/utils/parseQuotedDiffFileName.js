//#region src/utils/parseQuotedDiffFileName.ts
const filenameDecoder = new TextDecoder("utf-8", { ignoreBOM: true });
const NAMED_ESCAPES = {
	"\"": "\"",
	"\\": "\\",
	a: "\x07",
	b: "\b",
	t: "	",
	n: "\n",
	v: "\v",
	f: "\f",
	r: "\r"
};
function parseQuotedDiffFileName(input) {
	if (input[0] !== "\"") return;
	let fileName = "";
	let index = 1;
	while (index < input.length) {
		const char = input[index];
		if (char === "\"") return {
			fileName,
			rawLength: index + 1
		};
		if (char !== "\\") {
			fileName += char;
			index++;
			continue;
		}
		const escaped = NAMED_ESCAPES[input[index + 1]];
		if (escaped != null) {
			fileName += escaped;
			index += 2;
			continue;
		}
		const bytes = [];
		do {
			const byte = readOctalByte(input, index + 1);
			if (byte == null) return;
			bytes.push(byte);
			index += 4;
		} while (input[index] === "\\" && input[index + 1] >= "0" && input[index + 1] <= "7");
		fileName += filenameDecoder.decode(new Uint8Array(bytes));
	}
}
function readOctalByte(input, index) {
	const first = input.charCodeAt(index) - 48;
	const second = input.charCodeAt(index + 1) - 48;
	const third = input.charCodeAt(index + 2) - 48;
	if (first >= 0 && first <= 3 && second >= 0 && second <= 7 && third >= 0 && third <= 7) return first * 64 + second * 8 + third;
}
//#endregion
export { parseQuotedDiffFileName };

//# sourceMappingURL=parseQuotedDiffFileName.js.map