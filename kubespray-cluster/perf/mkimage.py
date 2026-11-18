#!/usr/bin/env python3
"""시험용 이미지를 OCI 레이아웃 디렉터리로 만든다. 레이어는 난수라서 압축·중복 제거가 되지 않는다.
   mkimage.py <디렉터리> <레이어 MB> [레이어 수=1]"""
import sys, os, io, json, tarfile, hashlib
d, mb, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 1
os.makedirs(f"{d}/blobs/sha256", exist_ok=True)
def put(b):
    h = hashlib.sha256(b).hexdigest(); open(f"{d}/blobs/sha256/{h}", "wb").write(b); return h
layers, diff = [], []
for i in range(n):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        data = os.urandom(mb * 1024 * 1024); ti = tarfile.TarInfo(f"data{i}.bin"); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    b = buf.getvalue(); h = put(b); diff.append("sha256:" + h)
    layers.append({"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:" + h, "size": len(b)})
cfg = json.dumps({"architecture": "amd64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": diff}, "config": {}}).encode()
ch = put(cfg)
man = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                  "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:" + ch, "size": len(cfg)}, "layers": layers}).encode()
mh = put(man)
json.dump({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:" + mh, "size": len(man)}]}, open(f"{d}/index.json", "w"))
json.dump({"imageLayoutVersion": "1.0.0"}, open(f"{d}/oci-layout", "w"))
