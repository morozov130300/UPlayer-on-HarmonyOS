// UPlayer MCP 代理（纯透传）：stdio <-> streamable-http
// 用途：让 BitFun / DevEco 等 MCP 客户端经 stdio 连接华为「开发者知识 MCP」。
//
// 服务端点（来自 mcpServers 配置「和谐发展知识」，类型 http）：
//   https://connect-api.cloud.huawei.com/api/developerknowledge/mcp
//
// 用法：
//   D:\Node\node D:\UPlayer\mcp-devknowledge.js
// 外部 MCP 客户端配置：
//   command: D:\Node\node.exe
//   args:    ["D:\\UPlayer\\mcp-devknowledge.js"]
//
// 实现说明：
//   - 仅用 Node 标准库（https / process），零 npm 依赖，直接运行无需参数。
//   - 本机为 Windows 标准 Node v24，TLS 正常，不需要子进程 / --jitless 等 workaround。
//   - 透传所有 JSON-RPC 消息（initialize / tools/list / tools/call / 通知等），
//     不修改工具描述；自动维护远程 Mcp-Session-Id；自动解析 JSON 与 SSE 两种响应。

'use strict';

const https = require('https');

const REMOTE_URL = 'https://connect-api.cloud.huawei.com/api/developerknowledge/mcp';
const TIMEOUT_MS = 30000;
const MAX_RETRIES = 3;
const RETRY_BASE_MS = 300;

let sessionId = null;

function log(...args) {
  console.error('[mcp-devknowledge]', ...args);
}

// 单条 JSON-RPC 消息 POST 到远程，返回 {status, contentType, body}。
// 网络层失败（超时/连接错误）reject，由调用方重试。
function post(payload) {
  const body = JSON.stringify(payload);
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'Content-Length': Buffer.byteLength(body),
  };
  if (sessionId) headers['Mcp-Session-Id'] = sessionId;

  return new Promise((resolve, reject) => {
    const req = https.request(REMOTE_URL, {
      method: 'POST',
      headers,
      agent: false, // 每次请求独立连接，避免长连接状态污染
      timeout: TIMEOUT_MS,
    }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { text += c; });
      res.on('end', () => {
        const sid = res.headers['mcp-session-id'];
        if (sid) sessionId = sid;
        resolve({
          status: res.statusCode,
          contentType: res.headers['content-type'] || '',
          body: text,
        });
      });
    });
    req.on('timeout', () => req.destroy(new Error('remote timeout')));
    req.on('error', (e) => reject(e));
    req.end(body);
  });
}

async function postWithRetry(payload) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await post(payload);
    } catch (e) {
      if (attempt >= MAX_RETRIES) throw new Error(String(e.message || e));
      log(`attempt ${attempt} failed (${e.message}), retrying...`);
      await new Promise((r) => setTimeout(r, RETRY_BASE_MS * attempt));
    }
  }
}

// 解析远程响应体：JSON 直接解析；SSE（text/event-stream）按空行分事件块，
// 每块内累积 data: 行后整体 JSON.parse。
function parseBody(contentType, body) {
  const ct = String(contentType || '').toLowerCase();
  if (ct.includes('text/event-stream')) {
    const messages = [];
    for (const block of body.split(/\r?\n\r?\n/)) {
      let data = '';
      for (const line of block.split(/\r?\n/)) {
        const t = line.trim();
        if (t.startsWith('data:')) {
          data += (data ? '\n' : '') + t.slice(5).trimStart();
        }
      }
      if (data) {
        try { messages.push(JSON.parse(data)); }
        catch { log('SSE data parse failed:', data.slice(0, 200)); }
      }
    }
    return messages;
  }
  try { return JSON.parse(body); }
  catch { return body; }
}

function out(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function fail(id, message) {
  if (id === undefined) return;
  out({ jsonrpc: '2.0', id, error: { code: -32000, message } });
}

async function handleLine(line) {
  let msg;
  try { msg = JSON.parse(line); }
  catch { log('invalid JSON, skipped:', line.slice(0, 120)); return; }

  let resp;
  try {
    resp = await postWithRetry(msg);
  } catch (e) {
    fail(msg.id, 'remote unreachable: ' + e.message);
    return;
  }

  if (resp.status >= 400) {
    fail(msg.id, `remote HTTP ${resp.status}: ${resp.body.slice(0, 500)}`);
    return;
  }

  // 204/空响应体：通知确认，无需回传
  if (!resp.body) return;

  const parsed = parseBody(resp.contentType, resp.body);
  const items = Array.isArray(parsed) ? parsed : [parsed];
  for (const r of items) {
    if (!r || typeof r !== 'object') continue;
    if (r.id !== undefined && (r.result !== undefined || r.error !== undefined)) {
      out(r); // 请求的响应，原样透传
    } else if (r.method !== undefined) {
      log('ignoring server-initiated request:', r.method); // 最小代理不处理服务端主动请求
    }
  }
}

// stdin：换行分隔的 JSON-RPC（MCP stdio 传输）
// 注意：客户端/管道可能先发完消息就关闭 stdin，此时必须等所有 in-flight
// 远程请求完成后再退出，否则响应会丢失。
function main() {
  let buf = '';
  const pending = new Set();
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line) continue;
      const p = handleLine(line);
      p.catch((e) => log('handler error:', String(e)));
      pending.add(p);
      p.then(() => pending.delete(p), () => pending.delete(p));
    }
  });
  process.stdin.on('end', () => {
    const drain = () => {
      if (pending.size === 0) process.exit(0);
      else setImmediate(drain);
    };
    drain();
  });
  log(`proxy started, target=${REMOTE_URL}`);
}

main();
