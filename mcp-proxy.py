#!/usr/bin/env python3
# UPlayer MCP 代理：stdio <-> streamable-http
# 用途：让 BitFun 通过 stdio 方式连接华为「开发者知识 MCP」（streamable-http 服务器）
# 本地处理 ping，转发 initialize / tools/list / tools/call 等，并维护远程会话。
#
# 用法：python3 mcp-proxy.py
# BitFun 外部 MCP 配置：
#   command: python3
#   args:    [D:\UPlayer\mcp-proxy.py]

import sys
import json
import ssl
import threading
from urllib.request import Request, urlopen
from urllib.error import HTTPError

REMOTE_URL = 'https://connect-api.cloud.huawei.com/api/developerknowledge/mcp'

# Use certifi CA bundle for SSL verification on HarmonyOS
CA_BUNDLE = '/storage/Users/currentUser/.local/lib/python3.12/site-packages/pip/_vendor/certifi/cacert.pem'

session_id = None
lock = threading.Lock()

AUTO_CALL_DESCRIPTION = '\n'.join([
    '',
    '【主动调用规则】',
    '当用户编写、修改或排查任何 HarmonyOS、ArkTS、ArkUI、DevEco Studio 相关代码时，必须主动调用此工具查询官方文档，无需等待用户明确要求调用 MCP。',
    '涉及系统 API、ArkUI 组件、装饰器、生命周期、权限、媒体、网络、存储、并发、构建配置、编译错误、运行错误或版本兼容性时，应优先查询官方文档，不要仅凭模型记忆猜测 API。'
])


def enhance_tools_list(method, result):
    if method != 'tools/list' or not result or not isinstance(result.get('tools'), list):
        return result
    tools = []
    for tool in result['tools']:
        if tool.get('name') != 'searchDocuments':
            tools.append(tool)
            continue
        tools.append({
            **tool,
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'SearchDocumentsReq': {
                        'type': 'object',
                        'description': '搜索请求',
                        'properties': {
                            'query': {'type': 'string', 'description': '搜索词'}
                        },
                        'required': ['query']
                    }
                },
                'required': ['SearchDocumentsReq']
            },
            'description': str(tool.get('description', '') or '') + AUTO_CALL_DESCRIPTION
        })
    return {**result, 'tools': tools}


def log(*args):
    print('[mcp-proxy]', *args, file=sys.stderr, flush=True)


def remote_request(payload, is_notification=False):
    global session_id
    body = json.dumps(payload).encode('utf-8')
    headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'Content-Length': str(len(body))
    }
    with lock:
        sid = session_id
    if sid:
        headers['Mcp-Session-Id'] = sid

    ctx = ssl.create_default_context(cafile=CA_BUNDLE)
    req = Request(REMOTE_URL, data=body, headers=headers, method='POST')

    try:
        with urlopen(req, timeout=60, context=ctx) as resp:
            raw = resp.read()
            new_sid = resp.headers.get('mcp-session-id')
            if new_sid:
                with lock:
                    session_id = new_sid[0] if isinstance(new_sid, list) else new_sid
            ct = (resp.headers.get('content-type') or '').lower()

            if resp.status == 202 or not raw:
                return None

            if 'text/event-stream' in ct:
                messages = []
                data = ''
                for line in raw.decode('utf-8').split('\r\n'):
                    t = line.strip()
                    if not t:
                        continue
                    if t.startswith('data:'):
                        chunk = t[5:].strip()
                        data = (data + '\n' if data else '') + chunk
                        try:
                            messages.append(json.loads(data))
                            data = ''
                        except Exception:
                            pass
                if data:
                    try:
                        messages.append(json.loads(data))
                    except Exception:
                        log('failed to parse SSE data:', data)
                return messages if messages else None

            return json.loads(raw)
    except HTTPError as e:
        if e.code == 202:
            return None
        raise
    except Exception as e:
        log('remote request error:', str(e))
        raise


def send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + '\n')
    sys.stdout.flush()


def send_error(id_, message):
    send({'jsonrpc': '2.0', 'id': id_, 'error': {'code': -32000, 'message': message}})


def handle_line(line):
    line = line.strip()
    if not line:
        return
    try:
        msg = json.loads(line)
    except Exception as e:
        log('invalid JSON input:', str(e))
        return

    method = msg.get('method')
    id_ = msg.get('id')

    if method == 'ping':
        send({'jsonrpc': '2.0', 'id': id_, 'result': {}})
        return

    if method in ('resources/list', 'resources/templates/list', 'prompts/list'):
        send({'jsonrpc': '2.0', 'id': id_, 'result': {'resources': [], 'templates': [], 'prompts': []}})
        return

    if method in ('resources/read', 'prompts/get'):
        send({'jsonrpc': '2.0', 'id': id_, 'result': {'contents': [], 'messages': []}})
        return

    if method == 'initialize':
        try:
            resp = remote_request(msg)
            if isinstance(resp, list):
                found = next((x for x in resp if x and ('result' in x or 'error' in x)), None)
                if found and 'error' in found:
                    send({'jsonrpc': '2.0', 'id': id_, 'error': found['error']})
                elif found and 'result' in found:
                    send({'jsonrpc': '2.0', 'id': id_, 'result': found['result']})
                else:
                    send_error(id_, 'remote initialize failed: ' + json.dumps(resp))
            elif isinstance(resp, dict):
                if 'error' in resp:
                    send({'jsonrpc': '2.0', 'id': id_, 'error': resp['error']})
                elif 'result' in resp:
                    send({'jsonrpc': '2.0', 'id': id_, 'result': resp['result']})
                else:
                    send_error(id_, 'remote initialize failed: ' + json.dumps(resp))
            else:
                send_error(id_, 'remote initialize failed: ' + json.dumps(resp))
        except Exception as e:
            send_error(id_, 'initialize error: ' + str(e))
        return

    if id_ is None:
        try:
            remote_request(msg, True)
        except Exception as e:
            log('notification forward failed:', str(e))
        return

    try:
        forward_msg = msg
        if method == 'tools/call' and msg.get('params') and msg['params'].get('arguments'):
            args = msg['params']['arguments']
            if 'SearchDocumentsReq' in args:
                forward_msg = {**msg, 'params': {**msg['params'], 'arguments': args['SearchDocumentsReq']}}
            elif 'GetDocumentsByIdRequest' in args:
                forward_msg = {**msg, 'params': {**msg['params'], 'arguments': args['GetDocumentsByIdRequest']}}

        resp = remote_request(forward_msg)

        if isinstance(resp, list):
            found = next((x for x in resp if x and ('result' in x or 'error' in x)), None)
            if found and 'error' in found:
                send({'jsonrpc': '2.0', 'id': id_, 'error': found['error']})
            else:
                result = found.get('result', {}) if found else {}
                send({'jsonrpc': '2.0', 'id': id_, 'result': enhance_tools_list(method, result)})
        elif isinstance(resp, dict):
            if 'error' in resp:
                send({'jsonrpc': '2.0', 'id': id_, 'error': resp['error']})
            elif 'result' in resp:
                send({'jsonrpc': '2.0', 'id': id_, 'result': enhance_tools_list(method, resp['result'])})
            else:
                send({'jsonrpc': '2.0', 'id': id_, 'result': {}})
        else:
            send({'jsonrpc': '2.0', 'id': id_, 'result': {}})
    except Exception as e:
        send_error(id_, 'forward error: ' + str(e))


if __name__ == '__main__':
    for line in sys.stdin:
        handle_line(line)