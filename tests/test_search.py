#!/usr/bin/env python3
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'Sources/Search.swift').read_text().split('final class GlobalShortcut')[0]
checks = r'''
let a = SearchEntry(path: "/tmp/报告/无关.txt", metadata: ["modified": 10, "size": 5, "directory": false], source: "本地")
let b = SearchEntry(path: "/tmp/计划报告.txt", metadata: ["modified": 20, "size": 10, "directory": false], source: "共享盘")
let byName = SearchCriteria(terms: ["报告"], scope: "", kind: .all)
precondition(!byName.includes(a) && byName.includes(b), "must match filename only")
precondition(SearchCriteria(terms: ["报告", "计划"], scope: "共享盘", kind: .text).includes(b))
precondition(!SearchCriteria(terms: ["报告"], scope: "本地", kind: .all).includes(b))
precondition(ResultOrdering.precedes(b, a, key: "modified", ascending: false))
precondition(ResultOrdering.precedes(a, b, key: "size", ascending: true))
print("search and sorting checks passed")
'''
with tempfile.TemporaryDirectory(dir='/private/tmp') as temp:
    p = pathlib.Path(temp); (p / 'main.swift').write_text(source + checks)
    subprocess.run(['swiftc', '-module-cache-path', str(p / 'cache'), str(p / 'main.swift'), '-o', str(p / 'test'), '-framework', 'Cocoa', '-framework', 'Quartz', '-framework', 'Carbon'], check=True)
    subprocess.run([str(p / 'test')], check=True)
