# 풀어 놓은 values·매니페스트 (prod-sample)

`./scripts/render-values.sh` 가 `templates/` 를 `prod-sample` 인벤토리 값으로 풀어 만든 파일이다. 손으로 고치지 않는다(다시 만들면 덮어쓴다).
`addons.yml` 이 하는 일을 helm·kubectl 명령으로 적으면 아래 순서다. 첫 control plane 에서, 이 디렉터리 안에서 실행한다.

| 파일 | 내용 | 값이 오는 곳 |
|---|---|---|
| `cilium-l2.yaml` | L2 공지 정책 (어느 노드·NIC 이 VIP 를 ARP 로 알릴지) | `node_iface` |
| `ingress-nginx-values.yaml` | ingress-nginx 차트 values (컨트롤러 3개, VIP 10.0.10.211) | `ingress_vip`, `ingress_replicas` |
| `longhorn-values.yaml` | Longhorn 차트 values | `longhorn_csi_replicas` |
| `longhorn-sc-single.yaml` | CNPG 용 StorageClass (복제 1벌, strict-local) | 고정 |
| `harbor-pg.yaml` | Harbor DB: CNPG Cluster 3 인스턴스 | `cnpg_storage_class`, `cnpg_storage_size`, `cnpg_smart_shutdown_timeout` |
| `harbor-values.yaml` | Harbor 차트 values (노출 방식 `ingress`) | `harbor_expose`, `harbor_host`, `harbor_storage_class`, `harbor_registry_size`, `harbor_db_host`, `harbor_db_secret` |
| `harbor-bgp-svc.yaml` | BGP VIP 를 받는 Service (`bgp_enabled: false`) | `harbor_bgp_vip` |

클러스터 자체의 설정(Kubernetes·Cilium·kube-vip·LB 풀·BGP)은 values 파일이 아니라 Kubespray 변수다: `prod-sample/group_vars/k8s_cluster/` 와 `group_vars/all/`.

## 순서

    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo add longhorn https://charts.longhorn.io
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo add harbor https://helm.goharbor.io
    helm repo update

    # 1. L2 공지 정책
    kubectl apply -f cilium-l2.yaml

    # 2. ingress-nginx
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
      --version 4.15.1 -f ingress-nginx-values.yaml --wait --timeout 10m

    # 3. Longhorn (worker 에 open-iscsi·nfs 클라이언트·커널 모듈 iscsi_tcp 가 먼저 있어야 한다 — addons.yml 첫 플레이)
    helm upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace \
      --version 1.13.0 -f longhorn-values.yaml --wait --timeout 15m
    kubectl apply -f longhorn-sc-single.yaml

    # 4. CloudNativePG operator + Harbor DB
    helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace \
      --version 0.29.1 --wait --timeout 10m
    kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f harbor-pg.yaml
    kubectl -n harbor wait cluster/harbor-pg --for=condition=Ready --timeout=15m

    # 5. Harbor. admin 비밀번호는 values 에 없다. Secret 으로 먼저 만든다(값은 직접 정한다)
    kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n harbor create secret generic harbor-admin --from-literal=HARBOR_ADMIN_PASSWORD='<비밀번호>'
    helm upgrade --install harbor harbor/harbor -n harbor --version 1.18.0 \
      -f harbor-values.yaml --wait --timeout 20m

    # 확인
    kubectl -n ingress-nginx get svc; kubectl -n harbor get ingress,pods
