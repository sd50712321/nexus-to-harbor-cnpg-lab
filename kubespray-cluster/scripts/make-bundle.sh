#!/usr/bin/env bash
# BUNDLE.md 생성: 다운로드·git clone 이 안 되는 곳으로 코드를 복사·붙여넣기로 옮기기 위한 문서.
#   파일마다 블럭 하나 = 그 파일을 만드는 셸 명령(heredoc). 마지막 블럭은 sha256 대조.
#   ./scripts/make-bundle.sh            → BUNDLE.md 생성
#   ./scripts/make-bundle.sh --check    → BUNDLE.md 를 빈 디렉터리에 풀어 원본과 대조
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I - "${1:-}" <<'PY'
import os, sys, hashlib, subprocess, tempfile, filecmp
D = '__KS_' + 'EOF__'          # heredoc 구분자 (이 파일 안에 그 줄이 그대로 나오지 않게 나눠 씀)
SKIP_DIRS = {'kubespray', '.venv', '.vagrant', 'secrets', 'logs', 'notes', '.git', 'artifacts', 'credentials'}
SKIP_FILES = {'ssh.cfg', 'BUNDLE.md'}
files = []
for root, dirs, names in os.walk('.'):
    dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
    for n in sorted(names):
        if n in SKIP_FILES or n.endswith('.md') or n == '.DS_Store':
            continue
        files.append(os.path.relpath(os.path.join(root, n)))
order = lambda p: (p.count('/'), p)
files.sort(key=order)

def check_file(p, data):
    lines = data.split('\n')
    if D in lines: sys.exit(f'{p}: heredoc 구분자와 같은 줄이 있다')
    if any(l.startswith('```') for l in lines): sys.exit(f'{p}: ``` 로 시작하는 줄이 있다 (마크다운 블럭이 깨짐)')
    if not data.endswith('\n'): sys.exit(f'{p}: 마지막 줄바꿈이 없다 (heredoc 이 줄바꿈을 붙여 sha256 이 달라짐)')

if sys.argv[1] == '--check':
    src = open('BUNDLE.md').read()
    blocks, cur = [], None
    for line in src.split('\n'):
        if cur is None and line == '```bash': cur = []
        elif cur is not None and line == '```': blocks.append('\n'.join(cur)); cur = None
        elif cur is not None: cur.append(line)
    with tempfile.TemporaryDirectory() as t:
        script = '\n'.join(blocks[1:]) + '\n'          # 0번은 README 안내용 mkdir 블럭
        r = subprocess.run(['bash', '-e'], input=script, text=True, cwd=t, capture_output=True)
        print(r.stdout[-3000:], r.stderr[-2000:])
        bad = [p for p in files if not filecmp.cmp(p, os.path.join(t, p), shallow=False)]
        modes = [p for p in files if os.access(p, os.X_OK) != os.access(os.path.join(t, p), os.X_OK)]
        print(f'파일 {len(files)}개, 내용 불일치 {len(bad)} {bad}, 실행권한 불일치 {len(modes)} {modes}, bash rc={r.returncode}')
        sys.exit(1 if bad or modes or r.returncode else 0)

out = []
w = out.append
w('# 코드 묶음 (붙여넣기용)\n')
w('다운로드·`git clone` 이 안 되는 곳으로 이 디렉터리를 옮길 때 쓴다. `scripts/make-bundle.sh` 가 만든 파일이므로 직접 고치지 않는다.\n')
w('1. 빈 디렉터리를 만들고 들어간다.\n')
w('```bash\nmkdir -p ~/kubespray-cluster && cd ~/kubespray-cluster\n```\n')
w('2. 아래 블럭을 위에서부터 차례로 복사해 터미널에 붙여넣는다. 블럭 하나가 파일 하나를 만든다. 붙여넣기가 불안하면 블럭들을 편집기로 `bundle.sh` 한 파일에 모은 뒤 `bash bundle.sh` 로 실행한다.\n')
w('3. 맨 아래 sha256 대조 블럭을 붙여넣어 모든 줄이 `OK` 인지 확인한다.\n')
w(f'파일 {len(files)}개. 문서(README·INFRA·TROUBLESHOOTING)는 GitHub 화면에서 바로 읽으면 되므로 넣지 않았다.\n')
w('| # | 파일 | 줄 수 |\n|---|---|---|')
datas = {}
for i, p in enumerate(files, 1):
    data = open(p, encoding='utf-8').read(); check_file(p, data); datas[p] = data
    w(f'| {i} | [{p}](#{i}-{p.replace("/", "").replace(".", "").replace("_", "_").lower()}) | {data.count(chr(10))} |')
w('')
for i, p in enumerate(files, 1):
    w(f'## {i}. {p}\n')
    w('```bash')
    d = os.path.dirname(p)
    if d: w(f"mkdir -p '{d}'")
    w(f"cat > '{p}' <<'{D}'")
    out.append(datas[p].rstrip('\n'))
    w(D)
    if os.access(p, os.X_OK): w(f"chmod +x '{p}'")
    w('```\n')
w('## sha256 대조\n')
w('리눅스는 `sha256sum -c`, macOS 는 `shasum -a 256 -c`. 모든 줄이 `OK` 여야 한다.\n')
w('```bash')
w(f"sha256sum -c <<'{D}'")
for p in files: w(f'{hashlib.sha256(datas[p].encode()).hexdigest()}  {p}')
w(D)
w('```')
open('BUNDLE.md', 'w').write('\n'.join(out) + '\n')
print(f'BUNDLE.md: 파일 {len(files)}개, {os.path.getsize("BUNDLE.md")} bytes')
PY
