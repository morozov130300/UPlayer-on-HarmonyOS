// UPlayer MCP 代理：stdio <-> streamable-http
// 用途：让 BitFun 通过 stdio 方式连接华为「开发者知识 MCP」（streamable-http 服务器）
// 本地处理 ping，转发 initialize / tools/list / tools/call 等，并维护远程会话。
//
// 用法：node mcp-proxy.js
// BitFun 外部 MCP 配置：
//   command: <node 完整路径>  例如 D:\DevEco Studio\tools\node\node.exe
//   args:    [D:\UPlayer\mcp-proxy.js]

'use strict';

const https = require('https');

const REMOTE_URL = 'https://connect-api.cloud.huawei.com/api/developerknowledge/mcp';

let sessionId = null;

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
      // 主动检索规则主要追加到文档搜索工具。
      if (tool.name !== 'searchDocuments') {
        return tool;
      }

      return {
        ...tool,
        // 华为服务器期望 SearchDocumentsReq 包装结构
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
  // 所有日志走 stderr，避免污染 stdout（stdout 只输出 JSON-RPC）
  console.error('[mcp-proxy]', ...args);
}

async function remoteRequest(payload, isNotification) {
  const body = JSON.stringify(payload);
  const url = new URL(REMOTE_URL);

  const headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'Content-Length': Buffer.byteLength(body)
  };

  if (sessionId) {
    headers['Mcp-Session-Id'] = sessionId;
  }

  const response = await new Promise((resolve, reject) => {
    const request = https.request(
      url,
      {
        method: 'POST',
        headers: headers
      },
      (res) => {
        const chunks = [];

        res.on('data', (chunk) => {
          chunks.push(chunk);
        });

        res.on('end', () => {
          resolve({
            status: res.statusCode,
            headers: res.headers,
            text: Buffer.concat(chunks).toString('utf8')
          });
        });

        res.on('error', reject);
      }
    );

    request.on('error', reject);
    request.end(body);
  });

  const newSess = response.headers['mcp-session-id'];

  if (newSess) {
    sessionId = Array.isArray(newSess) ? newSess[0] : newSess;
  }

  if (response.status === 202 || !response.text) {
    return null;
  }

  const ct = String(
    response.headers['content-type'] || ''
  ).toLowerCase();

  if (ct.includes('text/event-stream')) {
    const messages = [];
    let data = '';

    for (const line of response.text.split(/\r?\n/)) {
      const t = line.trim();

      if (!t) {
        continue;
      }

      if (t.startsWith('data:')) {
        const currentData = t.slice(5).trim();

        if (data) {
          data += '\n';
        }

        data += currentData;

        try {
          messages.push(JSON.parse(data));
          data = '';
        } catch (e) {
          // 数据不完整，继续累积
        }
      }
    }

    if (data) {
      try {
        messages.push(JSON.parse(data));
      } catch (e) {
        log('failed to parse SSE data:', data);
      }
    }

    return messages;
  }

  try {
    return JSON.parse(response.text);
  } catch (e) {
    return response.text;
  }
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
  input: process.stdin
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

  // ---- 本地处理 ping（华为服务器不支持 ping）----
  if (method === 'ping') {
    send({
      jsonrpc: '2.0',
      id: id,
      result: {}
    });

    return;
  }

  // ---- 本地处理 resources / prompts（华为服务器不支持，返回空）----
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
      const resp = await remoteRequest(msg, false);

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

  // ---- 其它请求：转发 ----
  try {
    // 对 tools/call 做参数适配：将 SearchDocumentsReq / GetDocumentsByIdRequest 包装层展开
    const forwardMsg = (() => {
      if (method === 'tools/call' && msg.params) {
        const args = msg.params.arguments;
        if (args) {
          // searchDocuments：展开 SearchDocumentsReq
          if (args.SearchDocumentsReq) {
            return {
              ...msg,
              params: {
                ...msg.params,
                arguments: args.SearchDocumentsReq
              }
            };
          }
          // getDocumentsById：展开 GetDocumentsByIdRequest
          if (args.GetDocumentsByIdRequest) {
            return {
              ...msg,
              params: {
                ...msg.params,
                arguments: args.GetDocumentsByIdRequest
              }
            };
          }
        }
      }
      return msg;
    })();

    const resp = await remoteRequest(forwardMsg, false);

    if (Array.isArray(resp)) {
      // 流式结果：取第一条含 result 或 error 的响应回传
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