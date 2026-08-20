#!/usr/bin/env bash
set -euo pipefail

WORK="$HOME/workspace/baseball_weight_backtest30"
mkdir -p "$WORK"
cd "$WORK"

cat > weight_backtest.py <<'PY'
import json,re,datetime,urllib.request,urllib.parse,csv
from collections import defaultdict

KST=datetime.timezone(datetime.timedelta(hours=9))
TODAY=datetime.datetime.now(KST).date()
START=TODAY-datetime.timedelta(days=30)
END=TODAY-datetime.timedelta(days=1)
HEAD={"User-Agent":"Mozilla/5.0","Accept-Language":"ko-KR,ko;q=0.9,ja;q=0.8,en;q=0.7"}

WEIGHTS={
 "현재형_80_20":{"season":80,"split":20},
 "완화A_70_20":{"season":70,"split":20},
 "완화B_60_20":{"season":60,"split":20},
 "균형형_65_25":{"season":65,"split":25},
}

def get(url,timeout=25):
    req=urllib.request.Request(url,headers=HEAD)
    with urllib.request.urlopen(req,timeout=timeout) as r:
        return r.read().decode("utf-8","ignore")

def get_json(url): return json.loads(get(url))

def clean(x):
    x=re.sub(r'<img\\b[^>]*\\balt=["\\']([^"\\']+)["\\'][^>]*>',lambda m:" "+m.group(1)+" ",x,flags=re.I)
    x=re.sub(r"<script.*?</script>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<style.*?</style>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<[^>]+>"," ",x)
    return re.sub(r"\\s+"," ",x).strip()

def pct(w,l): return w/(w+l) if w+l else .5
def rec(s):
    m=re.search(r"(\\d+)-(\\d+)",s or "")
    return (int(m.group(1)),int(m.group(2))) if m else (0,0)

def mlb_games():
    url="https://statsapi.mlb.com/api/v1/schedule?"+urllib.parse.urlencode({
        "sportId":1,"startDate":START.isoformat(),"endDate":END.isoformat(),"gameType":"R"})
    data=get_json(url);out=[]
    for d in data.get("dates",[]):
        for g in d.get("games",[]):
            if (g.get("status") or {}).get("abstractGameState")!="Final": continue
            t=g.get("teams") or {}
            a=(t.get("away") or {}).get("team",{}).get("name","")
            h=(t.get("home") or {}).get("team",{}).get("name","")
            ar=(t.get("away") or {}).get("score");hr=(t.get("home") or {}).get("score")
            if ar is None or hr is None or ar==hr: continue
            out.append({"date":d["date"],"away":a,"home":h,"winner":a if ar>hr else h})
    return out

def mlb_current():
    url="https://statsapi.mlb.com/api/v1/schedule?"+urllib.parse.urlencode({
        "sportId":1,"startDate":"2026-03-20","endDate":END.isoformat(),"gameType":"R"})
    data=get_json(url);st=defaultdict(lambda:{"W":0,"L":0,"HW":0,"HL":0,"AW":0,"AL":0})
    for d in data.get("dates",[]):
        for g in d.get("games",[]):
            if (g.get("status") or {}).get("abstractGameState")!="Final":continue
            t=g.get("teams") or {};a=(t.get("away") or {}).get("team",{}).get("name","");h=(t.get("home") or {}).get("team",{}).get("name","")
            ar=(t.get("away") or {}).get("score");hr=(t.get("home") or {}).get("score")
            if ar is None or hr is None or ar==hr:continue
            if ar>hr: st[a]["W"]+=1;st[a]["AW"]+=1;st[h]["L"]+=1;st[h]["HL"]+=1
            else: st[h]["W"]+=1;st[h]["HW"]+=1;st[a]["L"]+=1;st[a]["AL"]+=1
    return dict(st)

KBO_TEAMS=["HANWHA","LG","KIA","SAMSUNG","LOTTE","DOOSAN","KT","SSG","NC","KIWOOM"]

def kbo_current():
    txt=clean(get("https://eng.koreabaseball.com/Standings/TeamStandings.aspx"))
    out={}
    for tm in KBO_TEAMS:
        m=re.search(re.escape(tm)+r"\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+([0-9.]+)\\s+[-0-9.]+\\s+\\S+\\s+(\\d+-\\d+(?:-\\d+)?)\\s+(\\d+-\\d+(?:-\\d+)?)",txt,re.I)
        if not m:continue
        hw,hl=rec(m.group(6));aw,al=rec(m.group(7))
        out[tm]={"W":int(m.group(2)),"L":int(m.group(3)),"HW":hw,"HL":hl,"AW":aw,"AL":al}
    return out

def kbo_games():
    out=[]
    d=START
    alt="|".join(KBO_TEAMS)
    while d<=END:
        try: txt=clean(get(f"https://eng.koreabaseball.com/Schedule/Scoreboard.aspx?searchDate={d.isoformat()}"))
        except: d+=datetime.timedelta(days=1); continue
        seen=set()
        for m in re.finditer(r"("+alt+r").{0,60}?(\\d{1,2})\\s*:\\s*(\\d{1,2}).{0,60}?("+alt+r")",txt,re.I):
            a,ar,hr,h=m.group(1).upper(),int(m.group(2)),int(m.group(3)),m.group(4).upper()
            if a==h or ar==hr:continue
            key=(a,h,ar,hr)
            if key in seen:continue
            seen.add(key)
            out.append({"date":d.isoformat(),"away":a,"home":h,"winner":a if ar>hr else h})
        d+=datetime.timedelta(days=1)
    return out

NPB_MAP={
 "Hanshin Tigers":"한신","Yomiuri Giants":"요미우리","YOKOHAMA DeNA BAYSTARS":"DeNA",
 "Tokyo Yakult Swallows":"야쿠르트","Hiroshima Toyo Carp":"히로시마","Chunichi Dragons":"주니치",
 "Fukuoka SoftBank Hawks":"소프트뱅크","Saitama Seibu Lions":"세이부","Hokkaido Nippon-Ham Fighters":"니혼햄",
 "ORIX Buffaloes":"오릭스","Chiba Lotte Marines":"지바롯데","Tohoku Rakuten Golden Eagles":"라쿠텐"}

def npb_current():
    out={}
    for url in ("https://npb.jp/bis/eng/2026/stats/std_c.html","https://npb.jp/bis/eng/2026/stats/std_p.html"):
        txt=clean(get(url))
        for eng,kr in NPB_MAP.items():
            m=re.search(re.escape(eng)+r"\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+([.]?\\d+).{0,50}?(\\d+-\\d+)(?:\\s*\\(\\d+\\))?\\s+(\\d+-\\d+)",txt,re.I)
            if not m:continue
            hw,hl=rec(m.group(6));aw,al=rec(m.group(7))
            out[kr]={"W":int(m.group(2)),"L":int(m.group(3)),"HW":hw,"HL":hl,"AW":aw,"AL":al}
    return out

def npb_games():
    out=[];d=START;names=list(NPB_MAP.keys());alt="|".join(map(re.escape,names))
    while d<=END:
        try: txt=clean(get(f"https://npb.jp/bis/eng/2026/games/gm{d.strftime('%Y%m%d')}.html"))
        except: d+=datetime.timedelta(days=1);continue
        seen=set()
        for m in re.finditer(r"("+alt+r").{0,80}?(\\d{1,2})\\s*-\\s*(\\d{1,2}).{0,80}?("+alt+r")",txt,re.I):
            a=NPB_MAP[m.group(1)];h=NPB_MAP[m.group(4)];ar=int(m.group(2));hr=int(m.group(3))
            if a==h or ar==hr:continue
            key=(a,h,ar,hr)
            if key in seen:continue
            seen.add(key)
            out.append({"date":d.isoformat(),"away":a,"home":h,"winner":a if ar>hr else h})
        d+=datetime.timedelta(days=1)
    return out

def reverse_to_start(current,games):
    st={k:v.copy() for k,v in current.items()}
    for g in sorted(games,key=lambda x:x["date"],reverse=True):
        a,h,w=g["away"],g["home"],g["winner"]
        if a not in st or h not in st:continue
        l=h if w==a else a
        st[w]["W"]-=1;st[l]["L"]-=1
        if w==h:st[h]["HW"]-=1;st[a]["AL"]-=1
        else:st[a]["AW"]-=1;st[h]["HL"]-=1
    return st

def advance(st,g):
    a,h,w=g["away"],g["home"],g["winner"]
    if a not in st or h not in st:return
    l=h if w==a else a
    st[w]["W"]+=1;st[l]["L"]+=1
    if w==h:st[h]["HW"]+=1;st[a]["AL"]+=1
    else:st[a]["AW"]+=1;st[h]["HL"]+=1

def classify(g,st,wgt):
    a,h=g["away"],g["home"]
    if a not in st or h not in st:return None
    A,H=st[a],st[h]
    sa=50+(pct(A["W"],A["L"])-.5)*wgt["season"]+(pct(A["AW"],A["AL"])-.5)*wgt["split"]
    sh=50+(pct(H["W"],H["L"])-.5)*wgt["season"]+(pct(H["HW"],H["HL"])-.5)*wgt["split"]
    diff=abs(sa-sh);mx=max(sa,sh);pick=a if sa>=sh else h
    gr="BLUE" if diff>=12 and mx>=62 else "GREEN" if diff>=7 and mx>=57 else "HOLD" if diff>=3 else "OUT"
    return gr,pick,sa,sh

def evaluate(league,games,current):
    games=sorted(games,key=lambda x:x["date"])
    base=reverse_to_start(current,games)
    res={};details=[]
    for label,wgt in WEIGHTS.items():
        st={k:v.copy() for k,v in base.items()}
        agg={x:{"n":0,"hit":0} for x in ("BLUE","GREEN","HOLD","OUT")}
        byday=defaultdict(list)
        for g in games:
            r=classify(g,st,wgt)
            if r:
                gr,pick,sa,sh=r;hit=pick==g["winner"]
                agg[gr]["n"]+=1;agg[gr]["hit"]+=int(hit)
                if gr=="BLUE":byday[g["date"]].append(hit)
                details.append([league,label,g["date"],g["away"],g["home"],gr,pick,g["winner"],int(hit),round(sa,2),round(sh,2)])
            advance(st,g)
        combos=combo_hit=0
        for arr in byday.values():
            if len(arr)>=2:
                combos+=1;combo_hit+=int(arr[0] and arr[1])
        res[label]={"grades":agg,"combos":combos,"comboHit":combo_hit}
    return res,details

def fmt(h,n): return "-" if not n else f"{100*h/n:.1f}%"

def main():
    allres={};details=[]

    mg=mlb_games();mr,md=evaluate("MLB",mg,mlb_current());allres["MLB"]=mr;details+=md
    print("MLB",len(mg),"경기")

    kg=kbo_games();kr,kd=evaluate("KBO",kg,kbo_current());allres["KBO"]=kr;details+=kd
    print("KBO",len(kg),"경기")

    ng=npb_games();nr,nd=evaluate("NPB",ng,npb_current());allres["NPB"]=nr;details+=nd
    print("NPB",len(ng),"경기")

    print("\n"+"="*72)
    print(f"가중치 최근30일 비교  {START} ~ {END}")
    print("="*72)
    for league,res in allres.items():
        print("\n["+league+"]")
        for label,r in res.items():
            b=r["grades"]["BLUE"];g=r["grades"]["GREEN"]
            print(f"{label:14s}  BLUE {b['hit']}/{b['n']} {fmt(b['hit'],b['n']):>6}  "
                  f"GREEN {g['hit']}/{g['n']} {fmt(g['hit'],g['n']):>6}  "
                  f"2폴더 {r['comboHit']}/{r['combos']} {fmt(r['comboHit'],r['combos']):>6}")

    print("\n※ 현재 기록에서 최근30일 결과를 역산해 경기 직전 W/L·홈/원정 기록 복원")
    print("※ 경기 결과는 판정 후에만 반영")
    print("※ 선발 가산점은 3리그 동일 품질 복원이 어려워 이번 비교에서는 양팀 중립 처리")
    print("※ 따라서 시즌승률/홈원정 가중치를 낮췄을 때의 변화 비교용")

    with open("가중치30일결과.json","w",encoding="utf-8") as f:
        json.dump({"period":[START.isoformat(),END.isoformat()],"results":allres},f,ensure_ascii=False,indent=2)
    with open("가중치30일상세.csv","w",encoding="utf-8-sig",newline="") as f:
        w=csv.writer(f);w.writerow(["league","weight","date","away","home","grade","pick","winner","hit","awayScore","homeScore"]);w.writerows(details)

if __name__=="__main__":main()
PY

python3 weight_backtest.py | tee 가중치30일결과.txt

echo ""
echo "완료:"
echo "$WORK/가중치30일결과.txt"
echo "$WORK/가중치30일결과.json"
echo "$WORK/가중치30일상세.csv"
