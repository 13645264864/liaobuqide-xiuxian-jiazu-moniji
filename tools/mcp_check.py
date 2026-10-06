"""Local MCP diagnostics and private backup; no credentials printed."""
import json
import pathlib
import queue
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVER = pathlib.Path(r'C:\Users\23604\AppData\Local\npm-cache\_npx\88d9f76c32260533\node_modules\@cloudbase\cloudbase-mcp\dist\cli.cjs')
process = subprocess.Popen([r'F:\node.exe', str(SERVER)], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
messages = queue.Queue()

def read_stdout():
    for line in process.stdout:
        try:
            messages.put(json.loads(line))
        except ValueError:
            pass

threading.Thread(target=read_stdout, daemon=True).start()
threading.Thread(target=lambda: list(process.stderr), daemon=True).start()

def request(identifier, method, params):
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': params}) + '\n')
    process.stdin.flush()
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        try:
            item = messages.get(timeout=1)
        except queue.Empty:
            if process.poll() is not None:
                raise RuntimeError(f'MCP exited {process.returncode}')
            continue
        if item.get('id') == identifier:
            return item
    raise TimeoutError(method)

try:
    request(1, 'initialize', {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'family-cultivation-local', 'version': '0.1.0'}})
    process.stdin.write(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) + '\n')
    process.stdin.flush()
    if sys.argv[1] == 'schemas':
        result = request(2, 'tools/list', {})
    else:
        args = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8-sig'))
        result = request(2, 'tools/call', {'name': sys.argv[1], 'arguments': args})
    output = pathlib.Path(sys.argv[3])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=True), encoding='utf-8')
    print(json.dumps({'output': str(output), 'rpc_error': result.get('error'), 'tool_error': result.get('result', {}).get('isError', False)}))
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
