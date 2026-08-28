'use strict';
const fs = require('fs');
const path = require('path');
const { encodePNG, render, setStroke } = require('./render.js');

// Run from anywhere: paths resolve against the repo root, two levels up.
const REPO = path.resolve(__dirname, '..', '..');
const AMBER = [0xe9, 0xa1, 0x3b];   // MyTheme.accent, exactly
const WHITE = [0xff, 0xff, 0xff];

// A hairline that reads at 192px disappears at 16px, so the stroke thickens as
// the canvas shrinks. Same drawing, kept legible rather than kept literal.
function strokeFor(size) {
  if (size <= 24) return 0.075;
  if (size <= 48) return 0.055;
  if (size <= 96) return 0.045;
  return 0.038;
}
function png(size, inset, rgb) {
  setStroke(strokeFor(size));
  return encodePNG(size, size, render(size, inset, rgb));
}
function write(rel, buf) {
  const p = path.join(REPO, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, buf);
  console.log('  ' + rel + '  (' + buf.length + ' bytes)');
}

// ICO with PNG-compressed entries: valid since Vista, and far smaller than BMP.
function ico(entries) {
  const n = entries.length;
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0); header.writeUInt16LE(1, 2); header.writeUInt16LE(n, 4);
  const dir = Buffer.alloc(16 * n);
  let offset = 6 + 16 * n;
  entries.forEach((e, i) => {
    const o = i * 16;
    dir[o] = e.size >= 256 ? 0 : e.size;      // 0 means 256
    dir[o + 1] = e.size >= 256 ? 0 : e.size;
    dir.writeUInt16LE(1, o + 4);              // planes
    dir.writeUInt16LE(32, o + 6);             // bits per pixel
    dir.writeUInt32LE(e.png.length, o + 8);
    dir.writeUInt32LE(offset, o + 12);
    offset += e.png.length;
  });
  return Buffer.concat([header, dir, ...entries.map((e) => e.png)]);
}

const RES = 'flutter/android/app/src/main/res';
const DENS = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };

console.log('Android launcher:');
for (const [d, m] of Object.entries(DENS)) {
  const s = Math.round(48 * m);
  const b = png(s, 0.94, AMBER);
  write(RES + '/mipmap-' + d + '/ic_launcher.png', b);
  write(RES + '/mipmap-' + d + '/ic_launcher_round.png', b);
  // Adaptive foreground: 108dp canvas, art kept inside the 72dp safe zone or
  // the launcher's mask will clip the ears.
  write(RES + '/mipmap-' + d + '/ic_launcher_foreground.png',
        png(Math.round(108 * m), 0.64, AMBER));
  // Notification icons must be white on transparent; Android tints them.
  write(RES + '/mipmap-' + d + '/ic_stat_logo.png',
        png(Math.round(24 * m), 0.94, WHITE));
}

console.log('Windows:');
write('res/icon.png', png(512, 0.90, AMBER));
const icoBuf = ico([16, 24, 32, 48, 64, 128, 256].map((s) => ({ size: s, png: png(s, 0.90, AMBER) })));
write('res/icon.ico', icoBuf);
write('flutter/assets/icon.ico', icoBuf);
write('flutter/windows/runner/resources/app_icon.ico', icoBuf);
