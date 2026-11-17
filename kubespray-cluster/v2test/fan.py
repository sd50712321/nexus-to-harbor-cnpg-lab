#!/usr/bin/env python3
# 감시 에이전트 흉내: 마운트 하나에 fanotify 허가형(OPEN_PERM) 감시를 건다.
#   fan.py <마운트 경로> hang        이벤트를 읽지도 답하지도 않는다 (응답 없는 에이전트)
#   FAN_FS=1 을 주면 마운트 하나가 아니라 그 파일시스템 전체(컨테이너 안의 마운트 포함)를 감시한다
#   fan.py <마운트 경로> slow <초>   이벤트마다 <초> 뒤에 허용으로 답한다 (느린 에이전트)
import ctypes, os, struct, sys, time
libc = ctypes.CDLL("libc.so.6", use_errno=True)
FAN_CLASS_CONTENT, FAN_MARK_ADD, FAN_MARK_MOUNT, FAN_OPEN_PERM, FAN_ALLOW, AT_FDCWD = 0x4, 0x1, 0x10, 0x10000, 0x1, -100
path, mode = sys.argv[1], sys.argv[2]
fd = libc.fanotify_init(FAN_CLASS_CONTENT, os.O_RDONLY)
if fd < 0: sys.exit("fanotify_init errno %d" % ctypes.get_errno())
libc.fanotify_mark.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_uint64, ctypes.c_int, ctypes.c_char_p]
if libc.fanotify_mark(fd, FAN_MARK_ADD | (0x100 if os.environ.get("FAN_FS") else FAN_MARK_MOUNT), FAN_OPEN_PERM, AT_FDCWD, path.encode()) < 0:
    sys.exit("fanotify_mark errno %d" % ctypes.get_errno())
print("marked", path, mode, flush=True)
if mode == "hang":
    while True: time.sleep(3600)
delay = float(sys.argv[3])
while True:
    buf = os.read(fd, 4096); off = 0
    while off + 24 <= len(buf):
        elen, vers, _r, mlen, mask, efd, pid = struct.unpack_from("IBBHQii", buf, off); off += elen
        time.sleep(delay)
        os.write(fd, struct.pack("iI", efd, FAN_ALLOW)); os.close(efd)
