// UPlayer MCP 代理：stdio <-> streamable-http
// 用途：让 BitFun 通过 stdio 方式连接华为「开发者知识 MCP」（streamable-http 服务器）
// 本地处理 ping，转发 initialize / tools/list / tools/call 等，并维护远程会话。
//
// 用法：node mcp-proxy.js
// BitFun 外部 MCP 配置：
//   command: <node 完整路径>  例如 D:\DevEco Studio\tools\node\node.exe
//   args:    [D:\UPlayer\mcp-proxy.js]

'use strict';

const REMOTE_URL = 'https://connect-api.cloud.huawei.com/api/developerknowledge/mcp';

let sessionId = null;

function log(...args) {
  // 所有日志走 stderr，避免污染 stdout（stdout 只输出 JSON-RPC）
  console.error('[mcp-proxy]', ...args);
}

async function remoteRequest(payload, isNotification) {
  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream'
  };
  if (sessionId) {
    headers['Mcp-Session-Id'] = sessionId;
  }
  const res = await fetch(REMOTE_URL, {
    method: 'POST',
    headers: headers,
    body: JSON.stringify(payload)
  });
  const newSess = res.headers.get('mcp-session-id');
  if (newSess) {
    sessionId = newSess;
  }
  if (res.status === 202) {
    return null; // 通知类请求，服务器可能返回 202 无内容
  }
  const text = await res.text();
  if (!text) {
    return null;
  }
  const ct = (res.headers.get('content-type') || '').toLowerCase();
  if (ct.includes('text/event-stream')) {
    // 解析 SSE 事件（服务器也可能用 SSE 返回流式结果）
    const messages = [];
    let data = '';
    for (const line of text.split('\n')) {
      const t = line.trim();
      if (t.startsWith('data:')) {
        data += t.slice(5).trim();
        try {
          messages.push(JSON.parse(data));
          data = '';
        } catch (e) {
          // 数据不完整，继续累积
        }
      }
    }
    return messages;
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    return text;
  }
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function sendError(id, message) {
  send({ jsonrpc: '2.0', id: id, error: { code: -32000, message: message } });
}

const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin });

rl.on('line', async (line) => {
  line = line.trim();
  if (!line) {
    return;
  }
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    return;
  }
  const method = msg.method;
  const id = msg.id;

  // ---- 本地处理 ping（华为服务器不支持 ping）----
  if (method === 'ping') {
    send({ jsonrpc: '2.0', id: id, result: {} });
    return;
  }

  // ---- initialize：转发并回传 result ----
  if (method === 'initialize') {
    try {
      const resp = await remoteRequest(msg, false);
      if (resp && resp.result) {
        send({ jsonrpc: '2.0', id: id, result: resp.result });
      } else {
        sendError(id, 'remote initialize failed: ' + JSON.stringify(resp));
      }
    } catch (e) {
      sendError(id, 'initialize error: ' + String(e));
    }
    return;
  }

  // ---- 通知（无 id）----
  if (id === undefined) {
    try {
      await remoteRequest(msg, true);
    } catch (e) {
      log('notification forward failed:', String(e));
    }
    return;
  }

  // ---- 其它请求：转发 ----
  try {
    const resp = await remoteRequest(msg, false);
    if (Array.isArray(resp)) {
      // 流式结果：取第一条含 result 的响应回传
      const found = resp.find((x) => x && x.result !== undefined);
      send({ jsonrpc: '2.0', id: id, result: (found && found.result) || {} });
    } else if (resp && resp.error) {
      send({ jsonrpc: '2.0', id: id, error: resp.error });
    } else if (resp && resp.result !== undefined) {
      send({ jsonrpc: '2.0', id: id, result: resp.result });
    } else {
      send({ jsonrpc: '2.0', id: id, result: {} });
    }
  } catch (e) {
    sendError(id, 'forward error: ' + String(e));
  }
});
