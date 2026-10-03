#!/bin/bash
# Disposable infrastructure/CDP checks. Live streaming acceptance is separate.
set -euo pipefail
image="${1:?usage: scripts/graphics-smoke.sh LOCAL_PLUS_IMAGE}"
command -v docker >/dev/null || { echo 'Docker host required; no tests run' >&2; exit 1; }
name="dsh-graphics-smoke-$(date +%s)-$$"
for container in "$name" "${name}-disabled" "${name}-failure"; do
  if docker container inspect "$container" >/dev/null 2>&1; then
    echo "refusing to reuse $container" >&2; exit 1
  fi
done
cleanup() {
  case "$name" in dsh-graphics-smoke-[0-9]*-[0-9]*) ;; *) return 1;; esac
  docker rm -f "$name" "${name}-disabled" "${name}-failure" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'line=$LINENO status=$?; trap - ERR
  printf "graphics smoke failed at line %s (exit %s)\n" "$line" "$status" >&2
  for container in "$name" "${name}-disabled" "${name}-failure"; do
    docker inspect --format "{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}" "$container" >&2 || true
    docker logs --tail 100 "$container" >&2 || true
  done
  exit "$status"' ERR
hardened=(--read-only --cap-drop ALL --security-opt no-new-privileges:true
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --cap-add KILL
  --pids-limit 512 --shm-size 256m --stop-timeout 20
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=512m
  # Match production's exec-capable state volume: native addons load from its cache.
  --tmpfs /home/node/.dsh:rw,nosuid,nodev,exec,size=512m,uid=1234,gid=2345
  --tmpfs /workspace:rw,nosuid,nodev,noexec,size=64m,uid=1234,gid=2345
  -e PUID=1234 -e PGID=2345)
healthy() {
  for _ in $(seq 1 45); do
    state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1")
    [[ "$state" == 'running healthy' ]] && return 0
    [[ "$state" == running* ]] || { docker logs "$1"; return 1; }
    sleep 2
  done
  docker logs "$1"; return 1
}
docker run -d --name "${name}-disabled" "${hardened[@]}" "$image"
healthy "${name}-disabled"
docker exec "${name}-disabled" test ! -e /tmp/dsh-graphics-99/environment.json
docker stop "${name}-disabled" >/dev/null

docker run -d --name "$name" "${hardened[@]}" \
  -e DSH_GRAPHICS_ENABLED=true -e DSH_GRAPHICS_DISPLAY=:98 "$image"
healthy "$name"
docker exec -u 1234:2345 "$name" /usr/local/bin/dsh-graphics --check-graphics
# Never publish a production viewer, X11 or CDP port. Checks run inside test netns.
docker exec -i -u 1234:2345 "$name" python3 - <<'PY'
import base64, http.client, json, os, pathlib, re, socket, subprocess
root = pathlib.Path('/tmp/dsh-graphics-98')
m = json.loads((root/'environment.json').read_text())
env = {**os.environ, **m['environment']}
assert (root.stat().st_mode & 0o777) == 0o700
assert ((root/'Xauthority').stat().st_mode & 0o777) == 0o600
for pid in m['pids'].values():
    status = pathlib.Path(f'/proc/{pid}/status').read_text()
    assert re.search(r'^Uid:\s+1234\s+1234\s+1234\s+1234$', status, re.M), status
    assert re.search(r'^CapEff:\s+0+$', status, re.M), status
try:
    import pwd
    pwd.getpwuid(1234)
except KeyError:
    pass
else:
    raise AssertionError('test UID unexpectedly has passwd entry')
assert subprocess.run(['xdpyinfo'], env={**env, 'XAUTHORITY':'/tmp/no-such-graphics-cookie'},
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
for resolution in ('1920x1080', '1280x720'):
    subprocess.run(['selkies-resize', resolution], env=env, check=True, timeout=15)
    output = subprocess.check_output(['xdpyinfo'], env=env, text=True, timeout=3)
    actual = re.search(r'dimensions:\s+(\d+)x(\d+) pixels', output)
    assert actual and 'x'.join(actual.groups()) == resolution, output
def request(path, headers):
    c = http.client.HTTPConnection('127.0.0.1',8080,timeout=3)
    c.request('GET',path,headers=headers)
    status = c.getresponse().status
    c.close()
    return status
assert request('/',{}) == 200
ws = {'Connection':'Upgrade', 'Upgrade':'websocket','Sec-WebSocket-Version':'13',
      'Sec-WebSocket-Key':base64.b64encode(os.urandom(16)).decode()}
assert request('/api/websockets',{**ws,'Origin':'https://evil.invalid'}) == 403
assert request('/api/websockets',ws) == 101
listeners = subprocess.check_output(['ss','-lntH'],text=True)
assert not re.search(r'\S+:6098\s', listeners), listeners
for line in listeners.splitlines():
    if line.split()[3].endswith(':8080'):
        assert line.split()[3] == '127.0.0.1:8080', line
assert any(line.split()[3]=='127.0.0.1:8080' for line in listeners.splitlines()), listeners
# Only this explicit test launches Chrome, with isolated temporary profile.
for entry in pathlib.Path('/proc').iterdir():
    if entry.name.isdigit():
        try:
            assert os.readlink(entry/'exe') != '/opt/google/chrome/chrome', 'unexpected existing Chrome'
        except OSError:
            pass
log = open('/tmp/graphics-smoke-chrome.log','w')
chrome = subprocess.Popen(['google-chrome-stable','--no-sandbox','--disable-dev-shm-usage',
    '--disable-gpu','--ozone-platform=x11','--no-first-run','--no-default-browser-check',
    '--remote-debugging-address=127.0.0.1','--remote-debugging-port=9222',
    '--user-data-dir=/tmp/graphics-smoke-profile',
    'data:text/html,<title>Graphics smoke</title><input id=q><button onclick="alert(123)">dialog</button>'],
    env=env,stdout=log,stderr=log,start_new_session=True)
pathlib.Path('/tmp/graphics-smoke-chrome.pid').write_text(str(chrome.pid))
print('X11/audio/auth/WS/resize/non-passwd UID checks passed; manual Chrome pid',chrome.pid)
PY
for _ in $(seq 1 20); do
  docker exec "$name" node -e "fetch('http://127.0.0.1:9222/json/list').then(r=>r.json()).then(v=>process.exit(v.some(t=>t.title==='Graphics smoke')?0:1)).catch(()=>process.exit(1))" && break
  sleep 1
done
docker exec -i -u 1234:2345 "$name" node --input-type=module - <<'JS'
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
async function rpc(url, method, params = {}) {
  const ws = new WebSocket(url);
  const result = await new Promise((resolve,reject) => {
    const timeout = setTimeout(()=>{ws.close(); reject(new Error('CDP timeout'));},5000);
    ws.onopen = () => ws.send(JSON.stringify({id:1,method,params}));
    ws.onerror = reject;
    ws.onmessage = ({data}) => {const m=JSON.parse(data); if(m.id===1){clearTimeout(timeout); m.error?reject(m.error):resolve(m.result);}};
  });
  ws.close(); return result;
}
const browser = await fetch('http://127.0.0.1:9222/json/version').then(r=>r.json());
const info = await rpc(browser.webSocketDebuggerUrl,'SystemInfo.getProcessInfo');
const pid = Number(readFileSync('/tmp/graphics-smoke-chrome.pid','utf8'));
assert(info.processInfo.some(p=>p.type==='browser' && p.id===pid),'CDP must control test-owned Chrome PID');
const targets = await fetch('http://127.0.0.1:9222/json/list').then(r=>r.json());
const page = targets.find(t=>t.title==='Graphics smoke'); assert(page);
const result = await rpc(page.webSocketDebuggerUrl,'Runtime.evaluate',
  {expression:"document.querySelector('#q').value='CDP same-browser check'; document.querySelector('#q').value",returnByValue:true});
assert.equal(result.result.value,'CDP same-browser check');
console.log('CDP controls exact same headed Chrome PID',pid);
JS
if [[ "${KEEP_GRAPHICS_SMOKE:-false}" == true ]]; then
  docker rm -f "${name}-disabled" >/dev/null
  trap - EXIT
  printf 'Retained isolated container: %s\n' "$name"
  echo 'Interactive media checks and eventual test-container cleanup are now operator-owned; see docs/selkies.md.'
  exit 0
fi
docker exec -i -u 1234:2345 "$name" python3 - <<'PY'
import os,pathlib,signal,subprocess
listeners=subprocess.check_output(['ss','-lntH'],text=True)
assert any(l.split()[3]=='127.0.0.1:9222' for l in listeners.splitlines()),listeners
assert all(l.split()[3]=='127.0.0.1:9222' for l in listeners.splitlines() if l.split()[3].endswith(':9222')),listeners
os.killpg(int(pathlib.Path('/tmp/graphics-smoke-chrome.pid').read_text()),signal.SIGTERM)
PY
docker stop "$name" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$name")" = 0
docker logs "$name" 2>&1 | grep 'owned graphics processes reaped; private runtime removed' >/dev/null
# Independent fresh runtime: kill audio and require fail-closed DSH/service cleanup.
docker run -d --name "${name}-failure" "${hardened[@]}" \
  -e DSH_GRAPHICS_ENABLED=true -e DSH_GRAPHICS_DISPLAY=:98 "$image"
healthy "${name}-failure"
docker exec -u 1234:2345 "${name}-failure" python3 -c \
  'import json,os,signal; m=json.load(open("/tmp/dsh-graphics-98/environment.json")); os.kill(m["pids"]["PulseAudio"],signal.SIGKILL)'
for _ in $(seq 1 20); do
  [[ "$(docker inspect --format '{{.State.Status}}' "${name}-failure")" == exited ]] && break
  sleep 1
done
test "$(docker inspect --format '{{.State.Status}}' "${name}-failure")" = exited
test "$(docker inspect --format '{{.State.ExitCode}}' "${name}-failure")" = 1
docker logs "${name}-failure" 2>&1 | grep 'owned graphics processes reaped; private runtime removed' >/dev/null
echo 'Infrastructure/CDP smoke passed. Actual media/input/dialog/reconnect/CPU measurements still require viewer acceptance.'
