# Harbor 접속 정보. 시험 스크립트가 source 해서 쓴다 (랩 디렉터리에서 실행). 인벤토리의 ingress_vip / harbor_host 와 같아야 한다.
#   경로: 밖 → ingress-nginx VIP:443 → 호스트명으로 Harbor Ingress → core/portal
#   curl 은 --resolve 로 VIP 를 직접 지정해 DNS 없이도 된다. skopeo 는 이름을 풀 수 있어야 한다(랩: sslip.io, 실서버: 사내 DNS 또는 /etc/hosts)
#   실서버: INGRESS_VIP=<VIP> HARBOR_HOST=<호스트명> ./scripts/30-verify.sh
HV=${INGRESS_VIP:-172.16.141.211}
HH=${HARBOR_HOST:-harbor.$HV.sslip.io}
HB=$HH                    # skopeo 용 (docker://$HB/…)
HU=https://$HH            # API 주소
HA="admin:$(cat secrets/harbor-admin)"
hcurl(){ curl -sk --resolve "$HH:443:$HV" "$@"; }
