#!/usr/bin/env bash
set -euo pipefail

WORK="$HOME/workspace/baseball_green_focus_backtest30"
mkdir -p "$WORK"
cd "$WORK"

cat > green_focus.py <<'PY'
import json,re,datetime,urllib.request,urllib.parse,csv,statistics
from collections import defaultdict

KST=datetime.timezone(datetime.timedelta(hours=9))
TODAY=datetime.datetime.now(KST).date()
START=TODAY-datetime.timedelta(days=30)
END=TODAY-datetime.timedelta(days=1)
HEAD={"User-Agent":"Mozilla/5.0","Accept-Language":"ko-KR,ko;q=0.9,ja;q=0.8,en;q=0.7"}

def get(url,timeout=15):
    req=urllib.request.Request(url,headers=HEAD)
    with urllib.request.urlopen(req,timeout=timeout) as r:
        return r.read().decode("utf-8","ignore")

def get_json(url): return json.loads(get(url))
def clean(x):
    x=re.sub(r'<img\b[^>]*\balt=["\']([^"\']+)["\'][^>]*>',lambda m:" "+m.group(1)+" ",x,flags=re.I)
    x=re.sub(r"<script.*?</script>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<style.*?</style>"," ",x,flags=re.S|re.I)
    x=re.sub(r"<[^>]+>"," ",x)
    return re.sub(r"\s+"," ",x).strip()

def pct(w,l): return w/(w+l) if w+l else .5
def rec(s):
    m=re.search(r"(\d+)-(\d+)",s or "")
    return (int(m.group(1)),int(m.group(2))) if m else (0,0)

def mlb_games():
    data=get_json("https://statsapi.mlb.com/api/v1/schedule?"+urllib.parse.urlencode({
        "sportId":1,"startDate":START.isoformat(),"endDate":END.isoformat(),"gameType":"R"
    }))
    out=[]
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
    data=get_json("https://statsapi.mlb.com/api/v1/schedule?"+urllib.parse.urlencode({
        "sportId":1,"startDate":"2026-03-20","endDate":END.isoformat(),"gameType":"R"
    }))
    st=defaultdict(lambda:{"W":0,"L":0,"HW":0,"HL":0,"AW":0,"AL":0})
    for d in data.get("dates",[]):
        for g in d.get("games",[]):
            if (g.get("status") or {}).get("abstractGameState")!="Final": continue
            t=g.get("teams") or {}
            a=(t.get("away") or {}).get("team",{}).get("name","")
            h=(t.get("home") or {}).get("team",{}).get("name","")
            ar=(t.get("away") or {}).get("score");hr=(t.get("home") or {}).get("score")
            if ar is None or hr is None or ar==hr: continue
            if ar>hr:
                st[a]["W"]+=1;st[a]["AW"]+=1;st[h]["L"]+=1;st[h]["HL"]+=1
            else:
                st[h]["W"]+=1;st[h]["HW"]+=1;st[a]["L"]+=1;st[a]["AL"]+=1
    return dict(st)

KBO_TEAMS=["HANWHA","LG","KIA","SAMSUNG","LOTTE","DOOSAN","KT","SSG","NC","KIWOOM"]

def kbo_current():
    txt=clean(get("https://eng.koreabaseball.com/Standings/TeamStandings.aspx"))
    out={}
    for tm in KBO_TEAMS:
        m=re.search(re.escape(tm)+r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)\s+[-0-9.]+\s+\S+\s+(\d+-\d+(?:-\d+)?)\s+(\d+-\d+(?:-\d+)?)",txt,re.I)
        if not m: continue
        hw,hl=rec(m.group(6));aw,al=rec(m.group(7))
        out[tm]={"W":int(m.group(2)),"L":int(m.group(3)),"HW":hw,"HL":hl,"AW":aw,"AL":al}
    return out

def kbo_games():
    out=[]; d=START
    alt="|".join(KBO_TEAMS)
    while d<=END:
        print("KBO",d,flush=True)
        urls=[
            f"https://eng.koreabaseball.com/Schedule/Scoreboard.aspx?searchDate={d.isoformat()}",
            f"https://www.koreabaseball.com/Schedule/GameCenter/Main.aspx?gameDate={d.strftime('%Y%m%d')}"
        ]
        txt=""
        for u in urls:
            try:
                txt=clean(get(u))
                if len(txt)>500: break
            except: pass
        # Flexible score pattern
        seen=set()
        for m in re.finditer(r"("+alt+r").{0,120}?(\d{1,2})\s*[:\-]\s*(\d{1,2}).{0,120}?("+alt+r")",txt,re.I):
            a,ar,hr,h=m.group(1).upper(),int(m.group(2)),int(m.group(3)),m.group(4).upper()
            if a==h or ar==hr: continue
            key=(a,h,ar,hr)
            if key in seen: continue
            seen.add(key)
            out.append({"date":d.isoformat(),"away":a,"home":h,"winner":a if ar>hr else h})
        d+=datetime.timedelta(days=1)
    return out

NPB_MAP={
 "Hanshin Tigers":"한신","Yomiuri Giants":"요미우리","YOKOHAMA DeNA BAYSTARS":"DeNA",
 "Tokyo Yakult Swallows":"야쿠르트","Hiroshima Toyo Carp":"히로시마","Chunichi Dragons":"주니치",
 "Fukuoka SoftBank Hawks":"소프트뱅크","Saitama Seibu Lions":"세이부","Hokkaido Nippon-Ham Fighters":"니혼햄",
 "ORIX Buffaloes":"오릭스","Chiba Lotte Marines":"지바롯데","Tohoku Rakuten Golden Eagles":"라쿠텐"
}

def npb_current():
    out={}
    for url in ("https://npb.jp/bis/eng/2026/stats/std_c.html","https://npb.jp/bis/eng/2026/stats/std_p.html"):
        txt=clean(get(url))
        for eng,kr in NPB_MAP.items():
            m=re.search(re.escape(eng)+r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([.]?\d+).{0,80}?(\d+-\d+)(?:\s*\(\d+\))?\s+(\d+-\d+)",txt,re.I)
            if not m: continue
            hw,hl=rec(m.group(6));aw,al=rec(m.group(7))
            out[kr]={"W":int(m.group(2)),"L":int(m.group(3)),"HW":hw,"HL":hl,"AW":aw,"AL":al}
    return out

def npb_games():
    out=[];d=START
    names=list(NPB_MAP.keys());alt="|".join(map(re.escape,names))
    while d<=END:
        print("NPB",d,flush=True)
        url=f"https://npb.jp/bis/eng/2026/games/gm{d.strftime('%Y%m%d')}.html"
        try: txt=clean(get(url))
        except:
            d+=datetime.timedelta(days=1); continue
        seen=set()
        # Search both score orientations
        pats=[
            re.compile(r"("+alt+r").{0,140}?(\d{1,2})\s*-\s*(\d{1,2}).{0,140}?("+alt+r")",re.I),
            re.compile(r"("+alt+r").{0,140}?(\d{1,2})\s+(\d{1,2}).{0,140}?("+alt+r")",re.I)
        ]
        for pat in pats:
            for m in pat.finditer(txt):
                a=NPB_MAP[m.group(1)];h=NPB_MAP[m.group(4)]
                ar=int(m.group(2));hr=int(m.group(3))
                if a==h or ar==hr: continue
                key=(a,h,ar,hr)
                if key in seen: continue
                seen.add(key)
                out.append({"date":d.isoformat(),"away":a,"home":h,"winner":a if ar>hr else h})
        d+=datetime.timedelta(days=1)
    return out

def reverse_to_start(current,games):
    st={k:v.copy() for k,v in current.items()}
    for g in sorted(games,key=lambda x:x["date"],reverse=True):
        a,h,w=g["away"],g["home"],g["winner"]
        if a not in st or h not in st: continue
        l=h if w==a else a
        st[w]["W"]-=1; st[l]["L"]-=1
        if w==h: st[h]["HW"]-=1; st[a]["AL"]-=1
        else: st[a]["AW"]-=1; st[h]["HL"]-=1
    return st

def advance(st,g):
    a,h,w=g["away"],g["home"],g["winner"]
    if a not in st or h not in st:return
    l=h if w==a else a
    st[w]["W"]+=1; st[l]["L"]+=1
    if w==h: st[h]["HW"]+=1; st[a]["AL"]+=1
    else: st[a]["AW"]+=1; st[h]["HL"]+=1

def features(g,st):
    a,h=g["away"],g["home"]
    if a not in st or h not in st:return None
    A,H=st[a],st[h]
    a_season=pct(A["W"],A["L"]); h_season=pct(H["W"],H["L"])
    a_split=pct(A["AW"],A["AL"]); h_split=pct(H["HW"],H["HL"])
    sa=50+(a_season-.5)*80+(a_split-.5)*20
    sh=50+(h_season-.5)*80+(h_split-.5)*20
    pick=a if sa>=sh else h
    mx=max(sa,sh);diff=abs(sa-sh)
    gr="BLUE" if diff>=12 and mx>=62 else "GREEN" if diff>=7 and mx>=57 else "HOLD" if diff>=3 else "OUT"
    picked_season=a_season if pick==a else h_season
    picked_split=a_split if pick==a else h_split
    opp_season=h_season if pick==a else a_season
    season_gap=abs(a_season-h_season)
    split_gap=abs(a_split-h_split)
    return {
        "grade":gr,"pick":pick,"score":mx,"diff":diff,
        "seasonGap":season_gap,"splitGap":split_gap,
        "pickedSeason":picked_season,"pickedSplit":picked_split,
        "hit":pick==g["winner"]
    }

def run_rows(games,current):
    st=reverse_to_start(current,games)
    rows=[]
    for g in sorted(games,key=lambda x:x["date"]):
        f=features(g,st)
        if f: rows.append({**g,**f})
        advance(st,g)
    return rows

def stat(rows):
    n=len(rows);h=sum(1 for x in rows if x["hit"])
    return {"n":n,"hit":h,"acc":round(100*h/n,1) if n else None}

def green_segments(rows):
    g=[r for r in rows if r["grade"]=="GREEN"]
    ranked=sorted(g,key=lambda r:(r["score"],r["diff"]),reverse=True)
    top20=ranked[:max(1,round(len(ranked)*.20))] if ranked else []
    top30=ranked[:max(1,round(len(ranked)*.30))] if ranked else []
    return {
      "GREEN전체":stat(g),
      "GREEN상위20%":stat(top20),
      "GREEN상위30%":stat(top30),
      "시즌승률차7%이상":stat([r for r in g if r["seasonGap"]>=.07]),
      "시즌승률차10%이상":stat([r for r in g if r["seasonGap"]>=.10]),
      "홈원정차7%이상":stat([r for r in g if r["splitGap"]>=.07]),
      "홈원정차10%이상":stat([r for r in g if r["splitGap"]>=.10]),
      "추천팀시즌승률55%이상":stat([r for r in g if r["pickedSeason"]>=.55]),
      "추천팀홈원정55%이상":stat([r for r in g if r["pickedSplit"]>=.55]),
      "시즌55%+홈원정55%":stat([r for r in g if r["pickedSeason"]>=.55 and r["pickedSplit"]>=.55]),
    }

def print_segments(league,segs):
    print("\n["+league+" GREEN 세분화]")
    for k,v in segs.items():
        acc="-" if v["acc"] is None else f'{v["acc"]:.1f}%'
        print(f"{k:24s} {v['hit']}/{v['n']}  {acc}")

def main():
    allout={}
    print("▶ MLB 수집/검증",flush=True)
    mg=mlb_games();mr=run_rows(mg,mlb_current());ms=green_segments(mr)
    print("MLB 경기",len(mg),flush=True);print_segments("MLB",ms);allout["MLB"]=ms

    print("\n▶ KBO 수집/검증",flush=True)
    kg=kbo_games();kc=kbo_current()
    if kg and kc:
        kr=run_rows(kg,kc);ks=green_segments(kr);print("KBO 경기",len(kg));print_segments("KBO",ks);allout["KBO"]=ks
    else:
        print("KBO 과거 경기 파싱 0건 또는 순위 파싱 실패");allout["KBO"]={"error":"0 games or standings"}

    print("\n▶ NPB 수집/검증",flush=True)
    ng=npb_games();nc=npb_current()
    if ng and nc:
        nr=run_rows(ng,nc);ns=green_segments(nr);print("NPB 경기",len(ng));print_segments("NPB",ns);allout["NPB"]=ns
    else:
        print("NPB 과거 경기 파싱 0건 또는 순위 파싱 실패");allout["NPB"]={"error":"0 games or standings"}

    with open("GREEN_세분화_30일결과.json","w",encoding="utf-8") as f:
        json.dump({"period":[START.isoformat(),END.isoformat()],"results":allout},f,ensure_ascii=False,indent=2)

if __name__=="__main__":main()
PY

PYTHONUNBUFFERED=1 python3 -u green_focus.py | tee GREEN_세분화_30일결과.txt

echo ""
echo "완료:"
echo "$WORK/GREEN_세분화_30일결과.txt"
echo "$WORK/GREEN_세분화_30일결과.json"
