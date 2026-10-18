"""Snapshot one quarter of Stanford class meetings from ExploreCourses (public XML feed).

    python3 data/courses/fetch_explorecourses.py --year 20252026 --term Winter

Writes data/courses/<year>_<term>.csv.gz: one row per (section, meeting pattern) that has days and
times. The sim reads only this snapshot, so runs never touch the network and stay reproducible.
"""
import argparse
import csv
import gzip
import io
import os
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

BASE = "https://explorecourses.stanford.edu/"
VIEW = "xml-20200810"
DAY_ABBR = {"Monday": "M", "Tuesday": "T", "Wednesday": "W", "Thursday": "Th", "Friday": "F",
            "Saturday": "Sa", "Sunday": "Su"}
COLUMNS = ["subject", "code", "title", "course_id", "class_id", "component", "section", "units_min",
           "units_max", "gers", "num_enrolled", "max_enrolled", "days", "start", "end", "location",
           "start_date", "end_date"]


def get(url, tries=4):
    for k in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001 - retry any network error
            if k == tries - 1:
                raise
            print(f"  retry {url[-60:]}: {e}", file=sys.stderr)
            time.sleep(2 * (k + 1))


def departments():
    root = ET.fromstring(get(f"{BASE}?view={VIEW}"))
    return sorted({d.get("name") for d in root.iter("department")})


def hm(t):
    """'1:30:00 PM' -> '13:30'."""
    hms, ampm = t.split()
    h, m, _ = (int(x) for x in hms.split(":"))
    h = h % 12 + (12 if ampm == "PM" else 0)
    return f"{h:02d}:{m:02d}"


def dept_rows(dept, year, term):
    rows, page = [], 0
    while True:
        q = urllib.parse.urlencode({"view": VIEW, "academicYear": year, "page": page, "q": dept,
                                    f"filter-departmentcode-{dept}": "on", "filter-coursestatus-Active": "on",
                                    f"filter-term-{term}": "on"})
        root = ET.fromstring(get(f"{BASE}search?{q}"))
        courses = list(root.iter("course"))
        if not courses:
            return rows
        for co in courses:
            subj, code = co.findtext("subject"), co.findtext("code")
            if subj != dept:  # cross-listed copies are fetched under their own department
                continue
            gers = " ".join((co.findtext("gers") or "").split())
            for s in co.iter("section"):
                if not (s.findtext("term") or "").endswith(term):
                    continue
                for sc in s.iter("schedule"):
                    days = [DAY_ABBR[d] for d in (sc.findtext("days") or "").split() if d in DAY_ABBR]
                    st, en = sc.findtext("startTime") or "", sc.findtext("endTime") or ""
                    if not days or not st or not en:
                        continue
                    rows.append(dict(subject=subj, code=code, title=co.findtext("title"),
                                     course_id=s.findtext("courseId"), class_id=s.findtext("classId"),
                                     component=s.findtext("component"), section=s.findtext("sectionNumber"),
                                     units_min=co.findtext("unitsMin"), units_max=co.findtext("unitsMax"), gers=gers,
                                     num_enrolled=s.findtext("numEnrolled"), max_enrolled=s.findtext("maxEnrolled"),
                                     days="".join(days), start=hm(st), end=hm(en),
                                     location=" ".join((sc.findtext("location") or "").split()),
                                     start_date=sc.findtext("startDate"), end_date=sc.findtext("endDate")))
        page += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--year", default="20252026")
    ap.add_argument("--term", default="Winter", choices=["Autumn", "Winter", "Spring", "Summer"])
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    depts = departments()
    print(f"{len(depts)} departments")
    with ThreadPoolExecutor(a.workers) as ex:
        per = list(ex.map(lambda d: dept_rows(d, a.year, a.term), depts))
    rows = [r for rs in per for r in rs]
    rows.sort(key=lambda r: (r["subject"], r["code"], r["component"], r["section"], r["class_id"], r["days"],
                             r["start"], r["location"]))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"{a.year}_{a.term.lower()}.csv.gz")
    with gzip.GzipFile(out, "wb", mtime=0) as gz, io.TextIOWrapper(gz, "utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} meetings -> {out}")


if __name__ == "__main__":
    main()
