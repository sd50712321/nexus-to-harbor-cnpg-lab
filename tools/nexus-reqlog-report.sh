#!/bin/bash
# Nexus 3 request.log(+회전 request-*.log.gz) 분석 — 어느 IP/대역이 어떤 저장소·컴포넌트를 pull/push 했는지, 건수·바이트 기준 집계
#  로그 포맷(3.82 기본, etc/jetty/jetty-requestlog.xml):
#    IP - user [dd/MMM/yyyy:HH:mm:ss Z] "METHOD PATH HTTP/x" STATUS REQ_CONTENT_LENGTH BYTES_SENT ELAPSED_MS "User-Agent" [thread]
#  의존: bash, gzip, awk(gawk/mawk/BWK 모두 OK — mktime 등 gawk 전용 함수 미사용), sort
#  사용: nexus-reqlog-report.sh [-d LOGDIR | 파일...] [-s SINCE] [-u UNTIL] [-n TOP] [-i IPPREFIX] [-r REPO] [-a UA정규식] [-S 섹션,...]
#    -s/-u  'YYYY-MM-DD[ HH:MM[:SS]]'  — 로그에 찍힌 시간대 기준(변환 안 함)
#    -i     '10.20.'  처럼 접두 일치(대역),  -r 저장소 이름 정확 일치,  -a User-Agent 정규식
#    -S     summary,ip,subnet,repo,ipxrepo,component,push,time,ua,status,counter  (기본: 전부)
#    -c URL -A user:pass  → counter 섹션에서 usage-metrics API 값과 로그 집계를 나란히 출력
#  출력은 탭 구분. 바이트는 MB(1e6).  ※ 읽기 전용 — 로그 파일을 수정하지 않는다.
set -uo pipefail; export LC_ALL=C
LOGDIR=""; SINCE=""; UNTIL=""; TOP=15; IPP=""; REPO=""; UAR=""; SEC="summary,ip,subnet,repo,ipxrepo,component,push,time,ua,status,counter"; NXURL=""; NXCRED=""
while getopts "d:s:u:n:i:r:a:S:c:A:h" o; do case $o in d) LOGDIR=$OPTARG;; s) SINCE=$OPTARG;; u) UNTIL=$OPTARG;; n) TOP=$OPTARG;; i) IPP=$OPTARG;; r) REPO=$OPTARG;; a) UAR=$OPTARG;; S) SEC=$OPTARG;; c) NXURL=$OPTARG;; A) NXCRED=$OPTARG;; h|*) sed -n '2,13p' "$0"; exit 0;; esac; done; shift $((OPTIND-1))
norm(){ echo "$1" | awk '{gsub(/[^0-9]/,""); printf "%-14s", $0}' | tr ' ' '0'; }   # 'YYYY-MM-DD HH:MM' → 14자리
[ -n "$SINCE" ] && SINCE=$(norm "$SINCE"); [ -n "$UNTIL" ] && UNTIL=$(norm "$UNTIL" | sed 's/00000000$/23595999/;s/0000$/5999/')
if [ $# -gt 0 ]; then FILES=("$@"); else
  [ -z "$LOGDIR" ] && for d in /nexus-data/log /opt/sonatype/sonatype-work/nexus3/log ./log .; do [ -f $d/request.log ] && { LOGDIR=$d; break; }; done
  [ -z "$LOGDIR" ] && { echo "로그 디렉터리를 못 찾음: -d LOGDIR 지정" >&2; exit 1; }
  FILES=(); for f in "$LOGDIR"/request-*.log.gz "$LOGDIR"/request.log; do [ -f "$f" ] && FILES+=("$f"); done; fi
W=$(mktemp -d "${TMPDIR:-/tmp}/nxlog.XXXXXX"); trap 'rm -rf "$W"' EXIT; N=$W/n.tsv; T=$'\t'
has(){ case ",$SEC," in *",$1,"*) return 0;; esac; return 1; }
hdr(){ printf '\n== %s\n' "$1"; }
# ---------- 1패스: 정규화 TSV ----------
# 열: 1ts(14자리) 2ip 3subnet24 4user 5method 6path 7status 8reqBytes 9sentBytes 10ms 11ua 12repo 13component 14asset 15kind
for f in "${FILES[@]}"; do gzip -dcf "$f"; done | awk -v since="$SINCE" -v until="$UNTIL" -v ipp="$IPP" -v repo_f="$REPO" -v uar="$UAR" '
BEGIN{ OFS="\t"; split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",M," "); for(i=1;i<=12;i++) mon[M[i]]=sprintf("%02d",i) }
$6 !~ /^"[A-Z]+$/ { next }                                  # 형식 밖 줄 skip
{ t=substr($4,2); ts=substr(t,8,4) mon[substr(t,4,3)] substr(t,1,2) substr(t,13,2) substr(t,16,2) substr(t,19,2)
  if(since!="" && ts<since) next; if(until!="" && ts>until) next
  ip=$1; if(ipp!="" && index(ip,ipp)!=1) next
  user=$3; m=substr($6,2); path=$7; st=$9; rq=($10=="-")?0:$10; sb=($11=="-")?0:$11; ms=$12
  ua=$0; sub(/^[^"]*"[^"]*"[^"]*"/,"",ua); sub(/"[^"]*$/,"",ua); if(uar!="" && ua !~ uar) next
  if(index(ip,":")) { n=split(ip,o,":"); sn=o[1]":"o[2]":"o[3]":"o[4]"::/64" } else { split(ip,o,"."); sn=o[1]"."o[2]"."o[3]".0/24" }
  q=path; sub(/\?.*/,"",q)
  repo="-"; comp="-"; asset=q
  if(q ~ /^\/repository\/[^\/]+/){ r=q; sub(/^\/repository\//,"",r); repo=r; sub(/\/.*/,"",repo); rest=substr(q,length("/repository/"repo)+1)
    if(rest ~ /^\/v2\//){                                     # docker 형식
      d=rest; sub(/^\/v2\//,"",d)
      if(d ~ /\/manifests\//){ comp=d; sub(/\/manifests\/.*/,"",comp); ref=d; sub(/.*\/manifests\//,"",ref); asset="manifest "comp":"ref }
      else if(d ~ /\/blobs\//){ comp=d; sub(/\/blobs\/.*/,"",comp); asset=(d ~ /\/blobs\/uploads/)?"blob-upload "comp:"blob "comp }
      else if(d ~ /\/tags\/list$/){ comp=d; sub(/\/tags\/list$/,"",comp); asset="tags "comp }
      else { comp="(docker-api)"; asset="docker-api /"d }
    } else { asset=rest; comp=rest; sub(/\/[^\/]*$/,"",comp); if(comp=="") comp="/" }   # 그 외 형식: 컴포넌트=디렉터리
  } else if(q ~ /^\/v2\//){ repo="(v2-root)"; comp="(docker-api)" }
  else if(q ~ /^\/service\/rest\//){ repo="(rest-api)"; comp=q; sub(/\/[0-9a-f-]{20,}.*/,"",comp) }
  else if(q ~ /^\/service\//){ repo="(ui)" } else if(q ~ /^\/static\//){ repo="(static)" } else repo="(other)"
  if(repo_f!="" && repo!=repo_f) next
  kind=(m=="GET"||m=="HEAD")?"pull":(m=="PUT"||m=="POST"||m=="PATCH")?"push":"other"
  print ts,ip,sn,user,m,q,st,rq,sb,ms,ua,repo,comp,asset,kind }' > $N
[ -s $N ] || { echo "조건에 맞는 줄 없음"; exit 0; }
printf '입력: %s개 파일, 필터: since=%s until=%s ip=%s repo=%s ua=%s\n' "${#FILES[@]}" "${SINCE:--}" "${UNTIL:--}" "${IPP:--}" "${REPO:--}" "${UAR:--}"
# ---------- 공통 집계 함수: 키 열 번호(들) → 건수/pull/push/MB out/MB in/4xx5xx/고유IP/고유user ----------
agg(){ # $1=키열(쉼표 가능) $2=TOP $3=헤더
  awk -F'\t' -v keys="$1" -v top="$2" -v h="$3" 'BEGIN{OFS="\t"; nk=split(keys,K,",")}
  { k=$K[1]; for(i=2;i<=nk;i++) k=k"\t"$K[i]; c[k]++; if($15=="pull")pl[k]++; else if($15=="push")ps[k]++; out[k]+=$9; in_[k]+=$8; if($7>=400)er[k]++
    if(!(k SUBSEP $2 in ipseen)){ipseen[k SUBSEP $2]=1; nip[k]++}; if(!(k SUBSEP $4 in useen)){useen[k SUBSEP $4]=1; nu[k]++; ul[k]=(ul[k]==""?$4:(nu[k]<=3?ul[k]","$4:ul[k]))} }
  END{ print h"\t건수\tpull\tpush\tMB_out\tMB_in\t4xx5xx\tIP수\tuser수\tusers"
       for(k in c) printf "%s\t%d\t%d\t%d\t%.1f\t%.1f\t%d\t%d\t%d\t%s\n", k, c[k], pl[k], ps[k], out[k]/1e6, in_[k]/1e6, er[k], nip[k], nu[k], ul[k] }' $N \
  | { IFS= read -r l; echo "$l"; sort -t"$T" -k$(( $(echo "$1" | tr ',' '\n' | wc -l) + 1 )),$(( $(echo "$1" | tr ',' '\n' | wc -l) + 1 ))nr | head -n "$2"; }; }
if has summary; then hdr "요약"; awk -F'\t' '{n++; if(f==""||$1<f)f=$1; if($1>l)l=$1; ip[$2]=1; sn[$3]=1; u[$4]=1; o+=$9; i+=$8; k[$15]++; r[$12]=1}
  END{ni=0;for(x in ip)ni++; ns=0;for(x in sn)ns++; nu=0;for(x in u)nu++; nr=0;for(x in r)nr++
       printf "줄수 %d | 기간 %s ~ %s | 고유IP %d | /24대역 %d | user %d | 저장소(분류 포함) %d\n", n,f,l,ni,ns,nu,nr
       printf "pull %d / push %d / other %d | 보낸 바이트 %.1f MB | 받은 바이트(업로드) %.1f MB\n", k["pull"],k["push"],k["other"],o/1e6,i/1e6}' $N; fi
has ip      && { hdr "IP 별 (상위 $TOP, 건수순)"; agg 2 $TOP IP; }
has subnet  && { hdr "/24 대역 별"; agg 3 $TOP 대역; }
has repo    && { hdr "저장소 별"; agg 12 $TOP 저장소; }
has ipxrepo && { hdr "IP × 저장소 (상위 $TOP)"; agg 2,12 $TOP "IP	저장소"; }
if has component; then hdr "컴포넌트(이미지/디렉터리) 별 — 건수순 (상위 $TOP)"; agg 12,13 $TOP "저장소	컴포넌트"
  hdr "컴포넌트 별 — 전송량(MB_out)순 (상위 $TOP)"; agg 12,13 100000 "저장소	컴포넌트" | { IFS= read -r l; echo "$l"; sort -t"$T" -k6,6nr | head -n $TOP; }
  hdr "IP × 컴포넌트 (상위 $TOP) — '누가 무엇을'"; agg 2,12,13 $TOP "IP	저장소	컴포넌트"; fi
if has push; then hdr "push 성공 이벤트 (docker: PUT manifest 201 / 그 외: PUT·POST 2xx, 최근 $TOP건)"
  awk -F'\t' 'BEGIN{OFS="\t"; print "시각","IP","user","저장소","자산","MB_in"} ($15=="push" && $7<300 && $12 !~ /^\(/) && (($14 ~ /^manifest /) || ($14 !~ /^(blob|docker-api)/ && $5!="PATCH")) {printf "%s\t%s\t%s\t%s\t%s\t%.2f\n",$1,$2,$4,$12,$14,$8/1e6}' $N | { IFS= read -r l; echo "$l"; sort -r | head -n $TOP; }
  hdr "push 업로드량 IP 별 (PATCH/PUT 바디 합계)"; awk -F'\t' '$15=="push"{b[$2"\t"$4]+=$8; c[$2"\t"$4]++} END{print "IP\tuser\tpush요청수\tMB_in"; for(k in b) printf "%s\t%d\t%.1f\n",k,c[k],b[k]/1e6}' $N | { IFS= read -r l; echo "$l"; sort -t"$T" -k4,4nr | head -n $TOP; }; fi
if has time; then hdr "시간대 별 (시간 단위)"; awk -F'\t' '{h=substr($1,1,10); c[h]++; o[h]+=$9} END{for(h in c){printf "%s-%s-%s %s시\t%6d\t%8.1f MB\n",substr(h,1,4),substr(h,5,2),substr(h,7,2),substr(h,9,2),c[h],o[h]/1e6}}' mx=$(awk -F'\t' '{c[substr($1,1,10)]++} END{m=1;for(h in c)if(c[h]>m)m=c[h];print m}' $N) $N | sort | tail -n 48
  hdr "분 단위 피크 (usage-metrics 의 peak_requests_per_minute 과 대조용)"; awk -F'\t' '{c[substr($1,1,12)]++} END{for(m in c) print c[m]"\t"substr(m,1,4)"-"substr(m,5,2)"-"substr(m,7,2)" "substr(m,9,2)":"substr(m,11,2)}' $N | sort -nr | head -5; fi
if has ua; then hdr "User-Agent 계열 별"; awk -F'\t' '{u=$11; sub(/[ \/(].*/,"",u); if(u=="")u="(none)"; c[u]++; ip[u SUBSEP $2]=1} END{for(u in c){n=0; for(k in ip){split(k,a,SUBSEP); if(a[1]==u)n++} print c[u]"\t"n"\t"u}}' $N | sort -nr | head -n $TOP | { echo "건수	IP수	UA"; cat; }
  hdr "User-Agent 원문 (상위 $TOP)"; cut -f11 $N | sort | uniq -c | sort -nr | head -n $TOP; fi
if has status; then hdr "상태코드 별"; cut -f7 $N | sort | uniq -c | sort -nr; hdr "401 이 많은 IP (docker 토큰 핸드셰이크 포함 — 1 pull 당 /v2/ 401 1회가 정상)"; awk -F'\t' '$7==401{c[$2]++} END{for(i in c) print c[i]"\t"i}' $N | sort -nr | head -5; fi
if has counter; then hdr "카운터 귀속 — 최신 로그 시각 기준 24h 창 (usage-metrics requests_per_last_24h 과 대조)"
  awk -F'\t' '{l[NR]=$0; if($1>mx)mx=$1} END{y=mx; # 24시간 전 계산(날짜 넘김은 단순화: 같은 일 또는 전일)
    d=substr(y,1,8); hms=substr(y,9); split("31 28 31 30 31 30 31 31 30 31 30 31",DM," "); yr=substr(d,1,4)+0; mo=substr(d,5,2)+0; da=substr(d,7,2)+0; if(yr%4==0&&(yr%100!=0||yr%400==0))DM[2]=29
    da--; if(da<1){mo--; if(mo<1){mo=12;yr--}; da=DM[mo]}; th=sprintf("%04d%02d%02d%s",yr,mo,da,hms)
    for(i=1;i<=NR;i++){split(l[i],f,"\t"); if(f[1]>th){n++; cat=(f[12] ~ /^\(/)?f[12]:"/repository/*"; c[cat]++; if(f[12] !~ /^\(/ && f[7]<400)ok++}}
    printf "창: %s ~ %s\n로그 총 %d 건\n", th, mx, n; for(k in c) printf "  %-16s %d\n", k, c[k]; printf "  (repository 2xx/3xx만) %d\n", ok}' $N
  echo "시간(hour-of-day) 별 /repository/* 건수 — 로그에 있는 마지막 25개 시간 버킷, content_request_count.hour[시] 와 대조:"
  awk -F'\t' '$12 !~ /^\(/ {c[substr($1,1,10)]++} END{for(k in c) printf "  %s-%s-%s %s시\t%d\n",substr(k,1,4),substr(k,5,2),substr(k,7,2),substr(k,9,2),c[k]}' $N | sort | tail -n 25
  if [ -n "$NXURL" ]; then echo "usage-metrics API:"; curl -s ${NXCRED:+-u "$NXCRED"} "$NXURL/service/rest/internal/ui/usage-metrics"; echo
    echo "metrics/data content_request_count (hour[0..23] = 0시..23시 버킷):"; curl -s ${NXCRED:+-u "$NXCRED"} "$NXURL/service/rest/metrics/data" | grep -o '"nexus.analytics.content_request_count":{"value":{[^}]*}[^}]*}' | head -c 600; echo; fi; fi
