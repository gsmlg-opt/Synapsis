// A cursor owns its directory handles. Read exactly one entry at a time; never
// materialize or restart a wide directory between pages.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const root = process.argv[2];
const stack = [];
let started = false;
let closed = false;
let memoryIdentity = null;
const identity = stat => [stat.dev, stat.ino, stat.mtimeNs, stat.ctimeNs].join(':');
const fail = code => { throw Object.assign(new Error(code), { cursorCode: code }); };
function checkAncestors(directory) {
  let current = path.parse(directory).root;
  for (const component of directory.slice(current.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (!fs.lstatSync(current).isDirectory()) fail('unsafe_path');
  }
}
function open(relative) {
  if (Buffer.byteLength(relative) > 4096 || stack.length >= 128) fail('scan_limit');
  const absolute = path.join(root, relative);
  checkAncestors(absolute);
  const before = identity(fs.lstatSync(absolute, { bigint: true }));
  const dir = fs.opendirSync(absolute, { bufferSize: 1, encoding: 'utf8' });
  if (identity(fs.lstatSync(absolute, { bigint: true })) !== before) {
    dir.closeSync();
    fail('directory_changed');
  }
  stack.push({ relative, absolute, identity: before, dir });
}
function validate() {
  const memory = path.join(root, 'memory');
  try {
    checkAncestors(memory);
    if (identity(fs.lstatSync(memory, { bigint: true })) !== memoryIdentity)
      fail('directory_changed');
  } catch (error) {
    if (error.code !== 'ENOENT' || memoryIdentity !== null) throw error;
  }
  for (const frame of stack) {
    checkAncestors(frame.absolute);
    if (identity(fs.lstatSync(frame.absolute, { bigint: true })) !== frame.identity)
      fail('directory_changed');
  }
}
function close() {
  closed = true;
  while (stack.length) {
    try { stack.pop().dir.closeSync(); } catch (_) { /* already closed */ }
  }
}
function page(budget) {
  if (closed) fail('invalid_cursor');
  let scanned = 0;
  const entries = [];
  if (!started) {
    started = true;
    try {
      open('memory');
      memoryIdentity = stack[0].identity;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  validate();
  while (stack.length && scanned < budget) {
    const frame = stack[stack.length - 1];
    const entry = frame.dir.readSync();
    if (entry === null) {
      frame.dir.closeSync();
      stack.pop();
      continue;
    }
    scanned++;
    const relative = path.posix.join(frame.relative, entry.name);
    if (entry.name.includes('\\') || Buffer.byteLength(relative) > 4096) fail('unsafe_path');
    const stat = fs.lstatSync(path.join(root, relative));
    if (stat.isDirectory()) open(relative);
    else if (stat.isFile()) {
      if (entry.name.endsWith('.md')) entries.push(relative);
    } else fail('unsafe_path');
  }
  validate();
  return { entries, scanned, complete: stack.length === 0 };
}
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  try {
    const request = JSON.parse(line);
    if (!Number.isInteger(request.budget) || request.budget < 0 || request.budget > 128)
      fail('invalid_input');
    process.stdout.write(JSON.stringify(page(request.budget)) + '\n');
  } catch (error) {
    close();
    const code = error.cursorCode || (error.code === 'ENOENT' ? 'directory_changed' : 'unavailable');
    process.stdout.write(JSON.stringify({ error: code }) + '\n');
  }
});
input.on('close', () => { close(); process.exit(0); });
process.on('SIGTERM', () => { close(); process.exit(0); });
