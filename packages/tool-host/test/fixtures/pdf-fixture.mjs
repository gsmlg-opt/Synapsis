// Independent PDF 1.4 fixture: plain objects, text streams and an exact xref table.
// No browser, PDF writer package, network service or extractor generates these bytes.
export const FIRST_TEXT = Array.from({ length: 8 }, (_, i) => `First page line ${i + 1}: ordinary PDF text.`).join('\n');
export const THIRD_TEXT = Array.from({ length: 8 }, (_, i) => `Third page line ${i + 1}: another PDF page.`).join('\n');

export const ORDINARY_PAGES = [
  { text: FIRST_TEXT },
  { text: 'Sparse second page', color: [1, 0, 0] },
  { text: THIRD_TEXT },
  { color: [0, 0, 1] }
];

function literal(text) {
  return text.replaceAll('\\', '\\\\').replaceAll('(', '\\(').replaceAll(')', '\\)');
}

export function pdfFixture(pages = ORDINARY_PAGES) {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Count ${pages.length} /Kids [${pages.map((_, i) => `${4 + i * 2} 0 R`).join(' ')}] >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  ];
  for (const page of pages) {
    const { width = 144, height = 72, fontSize = 4, text = '', color } = page;
    const commands = [];
    if (color) commands.push(`${color.join(' ')} rg 0 0 ${width} ${height} re f`);
    for (const [i, line] of text.split('\n').entries()) {
      if (line) commands.push(`BT /F1 ${fontSize} Tf 0 g 4 ${height - 7 - i * (fontSize + 2)} Td (${literal(line)}) Tj ET`);
    }
    const stream = commands.join('\n');
    const contentId = objects.length + 2;
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${width} ${height}] /Resources << /Font << /F1 3 0 R >> >> /Contents ${contentId} 0 R >>`);
    objects.push(`<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`);
  }
  let document = '%PDF-1.4\n';
  const offsets = [0];
  for (const [i, object] of objects.entries()) {
    offsets.push(Buffer.byteLength(document));
    document += `${i + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = Buffer.byteLength(document);
  document += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  document += offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
  document += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(document, 'ascii');
}
