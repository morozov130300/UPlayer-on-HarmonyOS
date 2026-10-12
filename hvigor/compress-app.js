/*
 * UPlayer 构建后处理：无损压缩 APP 包
 *
 * 作用：把 signed .app 的 zip 条目存储方式从 STORED(0) 改为 DEFLATED(8, level 9)，
 *       解压后每个条目内容逐字节不变。
 *
 * 安全边界（重要）：
 *   - 只改外层 .app 的 zip 压缩方式，所有条目内容（含 entry-default.hap 的字节）保持完全一致；
 *   - 完整保留每个条目的 name / extra（HarmonyOS APP 签名块在此）/ comment / 时间戳 / 属性 / 顺序；
 *   - 不递归处理内层 hap，内层 zip 结构零改动 → 不影响 APP 签名与安装行为。
 *
 * 用法：node compress-app.js <app路径>  （原地重写，先写临时文件再原子替换）
 */
'use strict';

const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

const SIG_EOCD = 0x06054b50;
const SIG_CD = 0x02014b50;
const SIG_LFH = 0x04034b50;

function findEocd(buf) {
  const min = Math.max(0, buf.length - 65557);
  for (let i = buf.length - 22; i >= min; i--) {
    if (buf.readUInt32LE(i) === SIG_EOCD) return i;
  }
  return -1;
}

function crc32(buf) {
  // Node >= 22.2 内置
  return zlib.crc32(buf) >>> 0;
}

function recompressZip(buf) {
  const eocd = findEocd(buf);
  if (eocd < 0) throw new Error('not a zip: EOCD not found');
  const total = buf.readUInt16LE(eocd + 10);
  const cdOffset = buf.readUInt32LE(eocd + 16);
  const commentLen = buf.readUInt16LE(eocd + 20);
  const comment = buf.slice(eocd + 22, eocd + 22 + commentLen);

  // 解析中央目录
  const entries = [];
  let p = cdOffset;
  for (let i = 0; i < total; i++) {
    if (buf.readUInt32LE(p) !== SIG_CD) throw new Error('bad central dir signature at ' + p);
    const nameLen = buf.readUInt16LE(p + 28);
    const extraLen = buf.readUInt16LE(p + 30);
    const cmtLen = buf.readUInt16LE(p + 32);
    entries.push({
      versionMadeBy: buf.readUInt16LE(p + 4),
      versionNeeded: buf.readUInt16LE(p + 6),
      flags: buf.readUInt16LE(p + 8),
      modTime: buf.readUInt16LE(p + 12),
      modDate: buf.readUInt16LE(p + 14),
      internalAttr: buf.readUInt16LE(p + 36),
      externalAttr: buf.readUInt32LE(p + 38),
      localOffset: buf.readUInt32LE(p + 42),
      name: buf.slice(p + 46, p + 46 + nameLen),
      extra: buf.slice(p + 46 + nameLen, p + 46 + nameLen + extraLen),
      comment: buf.slice(p + 46 + nameLen + extraLen, p + 46 + nameLen + extraLen + cmtLen)
    });
    p += 46 + nameLen + extraLen + cmtLen;
  }

  // 逐条目重写：内容不变，仅换压缩方式
  const parts = [];
  let offset = 0;
  for (const e of entries) {
    const lp = e.localOffset;
    if (buf.readUInt32LE(lp) !== SIG_LFH) throw new Error('bad local header at ' + lp);
    const lNameLen = buf.readUInt16LE(lp + 26);
    const lExtraLen = buf.readUInt16LE(lp + 28);
    const lMethod = buf.readUInt16LE(lp + 8);
    const lCompSize = buf.readUInt32LE(lp + 18);
    const dataStart = lp + 30 + lNameLen + lExtraLen;
    const stored = buf.slice(dataStart, dataStart + lCompSize);

    let content;
    if (lMethod === 0) content = stored;
    else if (lMethod === 8) content = zlib.inflateRawSync(stored);
    else throw new Error('unsupported compression method ' + lMethod + ' for ' + e.name);

    const deflated = zlib.deflateRawSync(content, { level: 9 });
    const crc = crc32(content);

    // 本地头：保留 name/extra，清除 data-descriptor 标志(bit3)，写入真实尺寸
    e.flags &= ~0x08;
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(SIG_LFH, 0);
    lh.writeUInt16LE(Math.max(e.versionNeeded, 20), 4);
    lh.writeUInt16LE(e.flags, 6);
    lh.writeUInt16LE(8, 8);              // DEFLATE
    lh.writeUInt16LE(e.modTime, 10);
    lh.writeUInt16LE(e.modDate, 12);
    lh.writeUInt32LE(crc, 14);
    lh.writeUInt32LE(deflated.length, 18);
    lh.writeUInt32LE(content.length, 22);
    lh.writeUInt16LE(e.name.length, 26);
    lh.writeUInt16LE(e.extra.length, 28);

    e.localOffset = offset;
    e.crc = crc;
    e.compSize = deflated.length;
    e.uncompSize = content.length;

    parts.push(lh, e.name, e.extra, deflated);
    offset += lh.length + e.name.length + e.extra.length + deflated.length;
  }

  // 中央目录
  const cdStart = offset;
  for (const e of entries) {
    const c = Buffer.alloc(46);
    c.writeUInt32LE(SIG_CD, 0);
    c.writeUInt16LE(e.versionMadeBy, 4);
    c.writeUInt16LE(Math.max(e.versionNeeded, 20), 6);
    c.writeUInt16LE(e.flags, 8);
    c.writeUInt16LE(8, 10);
    c.writeUInt16LE(e.modTime, 12);
    c.writeUInt16LE(e.modDate, 14);
    c.writeUInt32LE(e.crc, 16);
    c.writeUInt32LE(e.compSize, 20);
    c.writeUInt32LE(e.uncompSize, 24);
    c.writeUInt16LE(e.name.length, 28);
    c.writeUInt16LE(e.extra.length, 30);
    c.writeUInt16LE(e.comment.length, 32);
    c.writeUInt16LE(0, 34);
    c.writeUInt16LE(e.internalAttr, 36);
    c.writeUInt32LE(e.externalAttr, 38);
    c.writeUInt32LE(e.localOffset, 42);
    parts.push(c, e.name, e.extra, e.comment);
    offset += c.length + e.name.length + e.extra.length + e.comment.length;
  }
  const cdSize = offset - cdStart;

  const eocdOut = Buffer.alloc(22);
  eocdOut.writeUInt32LE(SIG_EOCD, 0);
  eocdOut.writeUInt16LE(0, 4);
  eocdOut.writeUInt16LE(0, 6);
  eocdOut.writeUInt16LE(entries.length, 8);
  eocdOut.writeUInt16LE(entries.length, 10);
  eocdOut.writeUInt32LE(cdSize, 12);
  eocdOut.writeUInt32LE(cdStart, 16);
  eocdOut.writeUInt16LE(comment.length, 20);
  parts.push(eocdOut, comment);

  return Buffer.concat(parts);
}

function compressApp(appPath) {
  const input = fs.readFileSync(appPath);
  const output = recompressZip(input);
  const tmp = appPath + '.tmp';
  fs.writeFileSync(tmp, output);
  fs.renameSync(tmp, appPath);
  return { before: input.length, after: output.length };
}

if (require.main === module) {
  const target = process.argv[2];
  if (!target) {
    console.error('usage: node compress-app.js <app-path>');
    process.exit(1);
  }
  const r = compressApp(path.resolve(target));
  console.log(`[compress-app] ${target}: ${r.before} -> ${r.after} B (saved ${r.before - r.after}, ${((r.before - r.after) / r.before * 100).toFixed(1)}%)`);
}

module.exports = { compressApp, recompressZip };
