'use strict';
const zlib = require('zlib');

// ---------- PNG encoder (no deps; zlib is built in) ----------
let CRC = null;
function crcTable() {
  if (CRC) return CRC;
  CRC = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    CRC[n] = c;
  }
  return CRC;
}
function crc32(buf) {
  const t = crcTable();
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = t[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function encodePNG(w, h, rgba) {
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------- shapes as signed distances, in a 0..1 art box ----------
function ellipse(x, y, cx, cy, rx, ry, rot) {
  const c = Math.cos(rot || 0), s = Math.sin(rot || 0);
  const dx = x - cx, dy = y - cy;
  const u = (dx * c + dy * s) / rx, v = (-dx * s + dy * c) / ry;
  return (Math.hypot(u, v) - 1) * Math.min(rx, ry);
}

// A horse's ear is pointed, which an ellipse cannot be. This is a vesica --
// the intersection of two offset circles -- which comes to a point at both
// ends. halfLen/halfWid are solved back into the circle radius and offset.
function vesica(x, y, cx, cy, halfLen, halfWid, rot) {
  const R = (halfLen * halfLen + halfWid * halfWid) / (2 * halfWid);
  const o = R - halfWid;
  const c = Math.cos(rot || 0), s = Math.sin(rot || 0);
  const dx = x - cx, dy = y - cy;
  const u = dx * c + dy * s, v = -dx * s + dy * c;
  return Math.max(Math.hypot(u + o, v) - R, Math.hypot(u - o, v) - R);
}

// Proportions follow the original filled icon, which was already the approved
// character. The only change is what the shapes are made of -- strokes instead
// of fills -- plus pointed ears, and a muzzle pulled up so its stroke clears
// the head outline instead of merging into it.
const ART = {
  head: [0.5, 0.545, 0.300, 0.375, 0],
  muzzle: [0.5, 0.735, 0.160, 0.113, 0],
  eyeL: [0.378, 0.495, 0.047, 0.047, 0],
  eyeR: [0.622, 0.495, 0.047, 0.047, 0],
  nosL: [0.458, 0.745, 0.026, 0.026, 0],
  nosR: [0.542, 0.745, 0.026, 0.026, 0],
};
const EARS = [
  [0.312, 0.180, 0.146, 0.051, -0.32],
  [0.688, 0.180, 0.146, 0.051, 0.32],
];
let STROKE = 0.038;
function setStroke(v) { STROKE = v; }

function coverage(x, y) {
  const e = (k) => ellipse(x, y, ...ART[k]);
  // Unioned before stroking, so the outline reads as one continuous contour
  // with the ears growing out of it. Stroked separately, the head's arc would
  // run straight through each ear.
  const outline = Math.min(
    e('head'),
    vesica(x, y, ...EARS[0]),
    vesica(x, y, ...EARS[1]));
  const hw = STROKE / 2;
  if (Math.abs(outline) < hw) return 1;
  if (Math.abs(e('muzzle')) < hw) return 1;
  for (const k of ['eyeL', 'eyeR']) if (Math.abs(e(k)) < hw) return 1;
  for (const k of ['nosL', 'nosR']) if (e(k) < 0) return 1;
  return 0;
}

/** size: pixels. inset: fraction of the canvas the art occupies. */
function render(size, inset, rgb) {
  const SS = size <= 96 ? 8 : 4;
  const out = Buffer.alloc(size * size * 4);
  const pad = (1 - inset) / 2;
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let hit = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const fx = (px + (sx + 0.5) / SS) / size;
          const fy = (py + (sy + 0.5) / SS) / size;
          const ax = (fx - pad) / inset, ay = (fy - pad) / inset;
          if (ax < 0 || ax > 1 || ay < 0 || ay > 1) continue;
          hit += coverage(ax, ay);
        }
      }
      const a = Math.round((hit / (SS * SS)) * 255);
      const i = (py * size + px) * 4;
      out[i] = rgb[0]; out[i + 1] = rgb[1]; out[i + 2] = rgb[2]; out[i + 3] = a;
    }
  }
  return out;
}

module.exports = { encodePNG, render, setStroke };

if (require.main === module) {
  const fs = require('fs');
  const AMBER = [0xe9, 0xa1, 0x3b];
  fs.writeFileSync(process.argv[2] || 'preview.png',
    encodePNG(256, 256, render(256, 0.80, AMBER)));
  console.log('preview written');
}
