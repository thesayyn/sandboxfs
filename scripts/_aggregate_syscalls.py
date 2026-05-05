#!/usr/bin/env python3
"""Aggregate syscall data from xctrace XML for python3 worker thread.

Usage: xctrace export ... | _aggregate_syscalls.py <label>
"""
import re
import sys

label = sys.argv[1] if len(sys.argv) > 1 else "(unlabeled)"
text = sys.stdin.read()

proc_names = {}
syscall_names = {}
duration_ns = {}

for m in re.finditer(r'<process id="([0-9]+)" fmt="([^"(]+)\(([0-9]+)\)"', text):
    proc_names[m.group(1)] = m.group(2).strip()
for m in re.finditer(r'<syscall id="([0-9]+)" fmt="([^"]+)"', text):
    syscall_names[m.group(1)] = m.group(2)
for m in re.finditer(r'<duration id="([0-9]+)"[^>]*>([0-9]+)</duration>', text):
    duration_ns[m.group(1)] = int(m.group(2))

proc_inline = re.compile(r'<process id="([0-9]+)" fmt="([^"(]+)\(([0-9]+)\)"')
proc_refd = re.compile(r'<process ref="([0-9]+)"')
syscall_inline = re.compile(r'<syscall id="([0-9]+)" fmt="([^"]+)"')
syscall_refd = re.compile(r'<syscall ref="([0-9]+)"')
dur_inline = re.compile(r'<duration id="([0-9]+)"[^>]*>([0-9]+)</duration>')
dur_refd = re.compile(r'<duration ref="([0-9]+)"')


def get_proc(row):
    m = proc_inline.search(row)
    if m:
        return m.group(2).strip()
    m = proc_refd.search(row)
    if m:
        return proc_names.get(m.group(1))
    return None


def get_syscall(row):
    m = syscall_inline.search(row)
    if m:
        return m.group(2)
    m = syscall_refd.search(row)
    if m:
        return syscall_names.get(m.group(1))
    return None


def get_duration(row):
    m = dur_inline.search(row)
    if m:
        return int(m.group(2))
    m = dur_refd.search(row)
    if m:
        return duration_ns.get(m.group(1))
    return None


counts = {}
total_ns = {}
for row in re.split(r'<row>', text):
    proc = get_proc(row)
    if not proc or not proc.startswith("python"):
        continue
    sname = get_syscall(row)
    ns = get_duration(row)
    if sname is None or ns is None:
        continue
    counts[sname] = counts.get(sname, 0) + 1
    total_ns[sname] = total_ns.get(sname, 0) + ns

total = sum(total_ns.values())
n_total = sum(counts.values())
print(f"\n{label}")
print(f"  total: {total/1e6:.1f} ms across {n_total} syscalls")
print(f"  {'syscall':<22} {'count':>10} {'total ms':>10} {'avg µs':>8}")
for s in sorted(total_ns, key=lambda k: -total_ns[k])[:8]:
    print(f"  {s:<22} {counts[s]:>10} {total_ns[s]/1e6:>10.1f} {total_ns[s]/counts[s]/1000:>8.2f}")
