const { spawn } = require('child_process');
const proxyPath = '/storage/Users/currentUser/Desktop/Develop/UPlayer-on-HarmonyOS/mcp-proxy.js';
const nodeBin = '/data/service/hnp/bin/node';

function startProxy() {
  return new Promise((resolve, reject) => {
    const p = spawn(nodeBin, ['--jitless', proxyPath], { stdio: ['pipe', 'pipe', 'pipe'] });
    let buf = '';
    const pending = new Map();
    let nextId = 1;
    p.stdout.on('data', (d) => {
      buf += d.toString();
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim();
        buf = buf.slice(idx + 1);
        if (!line) continue;
        let m;
        try { m = JSON.parse(line); } catch (e) { continue; }
        if (m.id !== undefined && pending.has(m.id)) {
          const { resolve: r, reject: j } = pending.get(m.id);
          pending.delete(m.id);
          if (m.error) j(new Error('rpc error: ' + JSON.stringify(m.error)));
          else r(m.result);
        }
      }
    });
    p.stderr.on('data', () => {});
    p.on('exit', (c) => {
      for (const { reject: j } of pending.values()) j(new Error('proxy exited ' + c));
      pending.clear();
    });
    resolve({
      call(method, params) {
        const id = nextId++;
        return new Promise((res, rej) => {
          pending.set(id, { resolve: res, reject: rej });
          p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
        });
      },
      kill() { p.kill(); }
    });
  });
}

async function runRound(round) {
  const proxy = await startProxy();
  const results = {};
  try {
    const init = await proxy.call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '1.0' } });
    results.initialize = init && init.serverInfo ? 'OK' : 'FAIL';
    const tools = await proxy.call('tools/list', {});
    results.toolsList = Array.isArray(tools && tools.tools) ? ('OK(' + tools.tools.length + ' tools)') : 'FAIL';
    const search = await proxy.call('tools/call', { name: 'searchDocuments', arguments: { SearchDocumentsReq: { query: 'Grid 布局' } } });
    results.search = search && search.content ? 'OK' : 'FAIL';
    const getDoc = await proxy.call('tools/call', { name: 'getDocumentsById', arguments: { GetDocumentsByIdRequest: { names: ['document/cn/harmonyos-guides/web-same-layer'] } } });
    results.getDoc = getDoc && getDoc.content ? 'OK' : 'FAIL';
    const ping = await proxy.call('ping', {});
    results.ping = ping ? 'OK' : 'FAIL';
  } catch (e) {
    results.error = String(e.message || e);
  }
  proxy.kill();
  return results;
}

(async () => {
  for (let r = 1; r <= 3; r++) {
    const res = await runRound(r);
    console.log('ROUND ' + r + ': ' + JSON.stringify(res));
  }
  process.exit(0);
})();