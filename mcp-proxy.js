// UPlayer MCP 代理：stdio <-> streamable-http
// 用途：让 BitFun 通过 stdio 方式连接华为「开发者知识 MCP」（streamable-http 服务器）
// 本地处理 ping，转发 initialize / tools/list / tools/call 等，并维护远程会话。
//
// 用法：node --jitless mcp-proxy.js
// BitFun 外部 MCP 配置：
//   command: <node 可执行文件完整路径>
//   args:    ["--jitless", "<本项目 mcp-proxy.js 的绝对路径>"]
//
// 注意：此文件仅依赖 Node.js 标准库（https/readline），无需额外依赖。

'use strict';

const { spawn } = require('child_process');

const REMOTE_URL = 'https://connect-api.cloud.huawei.com/api/developerknowledge/mcp';

// 本机 node 为华为定制构建（musl + OpenSSL 3.5.4），连华为服务器做 HTTPS 请求时
// 单次请求有约 40-55% 的随机 SIGILL 崩溃率（TLS 层内存损坏，无法根治）。
// 因此每次远程请求都 spawn 一个独立子进程执行单次 HTTPS 请求：
//   - 子进程崩溃（SIGILL）不影响代理主进程
//   - 崩溃后由外层重试，直到成功，从而保证每次请求最终成功
let sessionId = null;

const MAX_RETRIES = 25;
const RETRY_DELAY_MS = 150;

const AUTO_CALL_DESCRIPTION = [
  '',
  '【主动调用规则】',
  '当用户编写、修改或排查任何 HarmonyOS、ArkTS、ArkUI、DevEco Studio 相关代码时，必须主动调用此工具查询官方文档，无需等待用户明确要求调用 MCP。',
  '涉及系统 API、ArkUI 组件、装饰器、生命周期、权限、媒体、网络、存储、并发、构建配置、编译错误、运行错误或版本兼容性时，应优先查询官方文档，不要仅凭模型记忆猜测 API。'
].join('\n');

function enhanceToolsList(method, result) {
  if (
    method !== 'tools/list' ||
    !result ||
    !Array.isArray(result.tools)
  ) {
    return result;
  }

  return {
    ...result,
    tools: result.tools.map((tool) => {
      if (tool.name !== 'searchDocuments') {
        return tool;
      }

      return {
        ...tool,
        inputSchema: {
          type: 'object',
          properties: {
            SearchDocumentsReq: {
              type: 'object',
              description: '搜索请求',
              properties: {
                query: { type: 'string', description: '搜索词' }
              },
              required: ['query']
            }
          },
          required: ['SearchDocumentsReq']
        },
        description:
          String(tool.description || '') + AUTO_CALL_DESCRIPTION
      };
    })
  };
}

function log(...args) {
  console.error('[mcp-proxy]', ...args);
}

// 在独立子进程中执行单次 HTTPS 请求，返回 {status, headers, text}。
// 子进程崩溃（SIGILL）时 reject，由 remoteRequest 重试。
function doRemoteRequest(payload, isNotification) {
  const body = JSON.stringify(payload);
  const sidStr = sessionId ? JSON.stringify(sessionId) : 'null';

  // 子进程脚本：发起单次 HTTPS 请求，把结果以 RESULT: 前缀输出到 stdout
  const childCode = `
    const https = require('https');
    const body = ${JSON.stringify(body)};
    const headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      'Content-Length': Buffer.byteLength(body),
      'Connection': 'close'
    };
    if (${sidStr} !== 'null') headers['Mcp-Session-Id'] = ${sidStr};
    const req = https.request(
      ${JSON.stringify(REMOTE_URL)},
      {
        method: 'POST',
        headers: headers,
        rejectUnauthorized: false,
        agent: false,
        timeout: 20000
      },
      (res) => {
        let text = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { text += c; });
        res.on('end', () => {
          console.log('RESULT:' + JSON.stringify({
            status: res.statusCode,
            session: res.headers['mcp-session-id'] || null,
            contentType: res.headers['content-type'] || null,
            text: text
          }));
          process.exit(0);
        });
        res.on('error', (e) => {
          console.log('RESULT:' + JSON.stringify({ error: e.message }));
          process.exit(0);
        });
      }
    );
    req.on('error', (e) => {
      console.log('RESULT:' + JSON.stringify({ error: e.message }));
      process.exit(0);
    });
    req.on('timeout', () => {
      req.destroy();
      console.log('RESULT:' + JSON.stringify({ error: 'timeout' }));
      process.exit(0);
    });
    req.end(body);
  `;

  return new Promise((resolve, reject) => {
    log('spawning child for method=' + (payload.method || '?'));
    const child = spawn(
      process.execPath,
      ['--jitless', '-e', childCode],
      { stdio: ['ignore', 'pipe', 'pipe'] }
    );

    let out = '';
    let err = '';
    let settled = false;

    child.stdout.on('data', (d) => { out += d.toString(); });
    child.stderr.on('data', (d) => { err += d.toString(); });

    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    child.on('exit', (code, signal) => {
      log('child exited: code=' + code + ' signal=' + signal + ' outLen=' + out.length);
      const m = out.match(/RESULT:(.*)/s);
      if (m) {
        try {
          const parsed = JSON.parse(m[1]);
          if (parsed.error) {
            reject(new Error('remote error: ' + parsed.error));
          } else {
            // 更新会话 ID（若服务器返回）
            if (parsed.session) {
              sessionId = parsed.session;
            }
            finish({
              status: parsed.status,
              headers: {
                'content-type': parsed.contentType || 'application/json',
                'mcp-session-id': parsed.session || null
              },
              text: parsed.text
            });
          }
        } catch (e) {
          reject(new Error('parse error: ' + e.message));
        }
      } else {
        // 子进程崩溃（SIGILL）或未输出结果
        reject(new Error('child crashed: code=' + code + ' signal=' + signal + ' stderr=' + err.slice(0, 100)));
      }
    });

    child.on('error', (e) => {
      log('child spawn error: ' + e.message);
      reject(new Error('spawn error: ' + e.message));
    });
  });
}

async function remoteRequest(payload, isNotification) {
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      return await doRemoteRequest(payload, isNotification);
    } catch (err) {
      if (attempt < MAX_RETRIES) {
        await new Promise(r => setTimeout(r, RETRY_DELAY_MS * attempt));
      } else {
        throw err;
      }
    }
  }
}

function parseResponse(resp) {
  if (!resp || typeof resp !== 'object') return resp;
  // doRemoteRequest 返回 {status, headers, text}，需要解析 text
  if (resp.text !== undefined) {
    const ct = String(resp.headers && resp.headers['content-type'] || '').toLowerCase();
    if (ct.includes('text/event-stream')) {
      const messages = [];
      let data = '';
      for (const line of resp.text.split(/\r?\n/)) {
        const t = line.trim();
        if (!t) continue;
        if (t.startsWith('data:')) {
          const currentData = t.slice(5).trim();
          if (data) data += '\n';
          data += currentData;
          try {
            messages.push(JSON.parse(data));
            data = '';
          } catch (e) { /* 数据不完整，继续累积 */ }
        }
      }
      if (data) {
        try { messages.push(JSON.parse(data)); } catch (e) { log('failed to parse SSE data:', data); }
      }
      return messages;
    }
    try { return JSON.parse(resp.text); } catch (e) { return resp.text; }
  }
  return resp;
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function sendError(id, message) {
  send({
    jsonrpc: '2.0',
    id: id,
    error: {
      code: -32000,
      message: message
    }
  });
}

const readline = require('readline');

const rl = readline.createInterface({
  input: process.stdin,
  terminal: false,
  // 防止 readline 在 stdin 关闭时自动调用 process.exit()
  // 避免 Node.js --jitless + musl 在异步请求未完成时触发 SIGILL
  close: false
});

rl.on('line', async (line) => {
  line = line.trim();

  if (!line) {
    return;
  }

  let msg;

  try {
    msg = JSON.parse(line);
  } catch (e) {
    log('invalid JSON input:', String(e));
    return;
  }

  const method = msg.method;
  const id = msg.id;

  // ---- 本地处理 ping ----
  if (method === 'ping') {
    send({
      jsonrpc: '2.0',
      id: id,
      result: {}
    });
    return;
  }

  // ---- 本地处理 resources / prompts ----
  if (
    method === 'resources/list' ||
    method === 'resources/templates/list' ||
    method === 'prompts/list'
  ) {
    send({
      jsonrpc: '2.0',
      id: id,
      result: {
        resources: [],
        templates: [],
        prompts: []
      }
    });
    return;
  }

  if (method === 'resources/read' || method === 'prompts/get') {
    send({
      jsonrpc: '2.0',
      id: id,
      result: {
        contents: [],
        messages: []
      }
    });
    return;
  }

  // ---- initialize：转发并回传 result ----
  if (method === 'initialize') {
    try {
      const rawResp = await remoteRequest(msg, false);
      const resp = parseResponse(rawResp);

      if (Array.isArray(resp)) {
        const found = resp.find(
          (item) =>
            item &&
            (
              item.result !== undefined ||
              item.error !== undefined
            )
        );

        if (found && found.error) {
          send({
            jsonrpc: '2.0',
            id: id,
            error: found.error
          });
        } else if (found && found.result !== undefined) {
          send({
            jsonrpc: '2.0',
            id: id,
            result: found.result
          });
        } else {
          sendError(
            id,
            'remote initialize failed: ' + JSON.stringify(resp)
          );
        }
      } else if (resp && resp.error) {
        send({
          jsonrpc: '2.0',
          id: id,
          error: resp.error
        });
      } else if (resp && resp.result !== undefined) {
        send({
          jsonrpc: '2.0',
          id: id,
          result: resp.result
        });
      } else {
        sendError(
          id,
          'remote initialize failed: ' + JSON.stringify(resp)
        );
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

  // ---- 其它请求：直接转发 ----
  try {
    const rawResp = await remoteRequest(msg, false);
    const resp = parseResponse(rawResp);

    if (Array.isArray(resp)) {
      const found = resp.find(
        (x) =>
          x &&
          (
            x.result !== undefined ||
            x.error !== undefined
          )
      );

      if (found && found.error) {
        send({
          jsonrpc: '2.0',
          id: id,
          error: found.error
        });
      } else {
        const result = found && found.result !== undefined
          ? found.result
          : {};

        send({
          jsonrpc: '2.0',
          id: id,
          result: enhanceToolsList(method, result)
        });
      }
    } else if (resp && resp.error) {
      send({
        jsonrpc: '2.0',
        id: id,
        error: resp.error
      });
    } else if (resp && resp.result !== undefined) {
      send({
        jsonrpc: '2.0',
        id: id,
        result: enhanceToolsList(method, resp.result)
      });
    } else {
      send({
        jsonrpc: '2.0',
        id: id,
        result: {}
      });
    }
  } catch (e) {
    sendError(id, 'forward error: ' + String(e));
  }
});

// stdin 关闭时退出。close:false 使 readline 不自动退出，交给这里显式退出。
rl.on('close', () => {
  process.exit(0);
});

// 兼容：某些 Node 版本中 stdin 结束时只触发 'end' 不触发 'close'
process.stdin.on('end', () => {
  process.exit(0);
});
