#!/usr/bin/env python3
import glob
import os
import re
import sys
from collections import Counter, defaultdict
from math import sqrt

TOPOS = ('central', 'star', 'mesh')

TIMEOUT_FRACTION = 0.99
QUERY_TIMEOUT_MS = 8000.0

def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    k = (len(sorted_vals) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)

def pop_mean_sd(vals):

    n = len(vals)
    if n == 0:
        return (0.0, 0.0, 0)
    m = sum(vals) / n
    if n > 1:
        sd = sqrt(sum((v - m) * (v - m) for v in vals) / n)
    else:
        sd = 0.0
    return (m, sd, n)

class RunFile:

    def __init__(self, path, topo, exp, node, run):
        self.path = path
        self.topo = topo
        self.exp = exp
        self.node = node
        self.run = run

        self.rows = []
        self.scale = 1.0
        self.v3 = False

    def load(self):
        with open(self.path, 'r') as f:
            header = f.readline().strip().split(',')
        if 'duration_us' in header:
            self.scale = 0.001
        elif 'duration_ms' not in header:
            raise ValueError('unrecognized header in %s: %s' %
                             (self.path, ','.join(header)))
        self.v3 = 'query_us' in header
        with open(self.path, 'r') as f:
            f.readline()
            for line in f:
                p = line.rstrip('\n').split(',')
                if len(p) < 9:
                    continue
                try:
                    ts_end = float(p[1]) * self.scale
                    client = int(p[2])
                    seq = int(p[3])
                    name = p[4]
                    op = p[5]
                    ok = int(p[6])
                    dur = float(p[7]) * self.scale
                    byt = int(p[8])
                    qms = dms = 0.0
                    hip = nh = 0
                    if self.v3 and len(p) >= 13:
                        qms = float(p[9]) * self.scale
                        dms = float(p[10]) * self.scale
                        hip = int(p[11])
                        nh = int(p[12])
                except ValueError:
                    continue
                self.rows.append((ts_end - dur, dur, op, ok, byt, name, seq,
                                  client, qms, dms, hip, nh))
        return self

NAME_RE = re.compile(
    r'(central|mesh|star)-(e[1-4]|fo-[a-z]+|[a-z]*micro[a-z]*|micro)-'
    r'(vm\d+|r\d+|local)-?r?u?n?(\d*)\.csv$')

def classify(path):

    base = os.path.basename(path)
    m = NAME_RE.match(base)
    if m:
        topo, exp, node, run = m.groups()
        return topo, exp, node, (int(run) if run else 1)
    m = re.match(r'(central|mesh|star)-micro-r(\d+)\.csv$', base)
    if m:
        return m.group(1), 'micro', 'local', int(m.group(2))
    m = re.match(r'failover-(small|large)\.csv$', base)
    if not m:
        m = re.match(r'fo-failover-(small|large)\.csv$', base)
    if m:

        d = re.search(r'failover-(central|star|mesh)', path)
        topo = d.group(1) if d else 'mesh'
        return topo, 'fo-' + m.group(1), 'vm13', 1
    m = re.match(r'(central|mesh|star)-e([1-4])-r(\d+)\.csv$', base)
    if m:
        return m.group(1), 'e' + m.group(2), 'local', int(m.group(3))
    return None

def gather(root, verify_dir=None):
    runs = defaultdict(list)
    files = glob.glob(os.path.join(root, '**', '*.csv'), recursive=True)
    for p in files:
        c = classify(p)
        if not c:
            print('skipping unrecognized csv: %s' % p)
            continue
        topo, exp, node, run = c
        rf = RunFile(p, topo, exp, node, run)
        rf.load()
        if not rf.rows:
            print('warning: no rows in %s' % p)
            continue
        runs[(topo, exp, run)].append(rf)
    if verify_dir:
        for p in glob.glob(os.path.join(verify_dir, 'csv', '*.csv')):
            c = classify(p)
            if not c:
                continue
            topo, exp, node, run = c
            rf = RunFile(p, topo, exp, node, run)
            try:
                rf.load()
            except ValueError:
                continue
            if rf.rows:
                runs[(topo, exp, run)].append(rf)
    return runs

def fmt_run(s):
    return ('ops=%6d ok=%6d fail=%4d t/o=%4d window=%8.1fs  '
            'throughput=%9.1f q/s  lat p50=%8.1f p95=%8.1f p99=%8.1f '
            'max=%9.1f ms  seqgaps=%d' %
            (s['n'], s['ok'], s['fail'], s['timeouts'], s['window_s'],
             s['rate'], s['p50'], s['p95'], s['p99'], s['max'], s['seqgaps']))

def summarize_run(rfs):

    starts, ends, durs_all, oks, fails, tos = [], [], [], 0, 0, 0
    byts, ops_obtain = 0, 0
    seqgap = 0

    pool_qrow, pool_q, pool_dl, pool_obtdur = [], [], [], []
    pool_nhits = []
    holders = Counter()
    for rf in rfs:
        per_client = defaultdict(list)
        for (ts_s, dur, op, ok, byt, name, seq, client,
             qms, dms, hip, nh) in rf.rows:
            starts.append(ts_s)
            ends.append(ts_s + dur)
            durs_all.append(dur)
            if ok:
                oks += 1
            else:
                fails += 1
                if dur >= TIMEOUT_FRACTION * QUERY_TIMEOUT_MS:
                    tos += 1
            byts += byt
            if op == 'obtain':
                ops_obtain += 1
                pool_obtdur.append(dur)
                if ok:
                    if qms > 0:
                        pool_q.append(qms)
                    if dms > 0:
                        pool_dl.append(dms)
                    if hip:
                        holders[hip & 0xFF] += 1
            else:
                pool_qrow.append(dur)
                pool_nhits.append(nh)
            per_client[client].append(seq)
        for seqs in per_client.values():
            seqs.sort()
            seqgap += sum(1 for a, b in zip(seqs, seqs[1:]) if b - a > 1)
    t0, t1 = min(starts), max(ends)
    window = max(t1 - t0, 1e-9)
    n = len(durs_all)
    ds = sorted(durs_all)
    return {
        'nproc': len(rfs),
        'nodes': sorted({rf.node for rf in rfs}),
        'n': n, 'ok': oks, 'fail': fails, 'timeouts': tos,
        'window_s': window / 1000.0,
        'rate': n / (window / 1000.0),
        'ok_rate': oks / (window / 1000.0),
        'mibs': (byts / (1024.0 * 1024.0)) / (window / 1000.0),
        'obtain_ops': ops_obtain,
        'seqgaps': seqgap,

        'p50': percentile(ds, 0.50), 'p95': percentile(ds, 0.95),
        'p99': percentile(ds, 0.99), 'max': ds[-1],
        'avg': (sum(ds) / len(ds)) if ds else 0.0,
        'durs_ms': ds,
        'pool_qrow': pool_qrow,
        'pool_q': pool_q,
        'pool_dl': pool_dl,
        'pool_obtdur': pool_obtdur,
        'pool_nhits': pool_nhits,
        'holders': holders,
    }

def _mm(vals):

    if not vals:
        return (0.0, 0.0)
    m = sum(vals) / len(vals)
    sd = sqrt(sum((v - m) * (v - m) for v in vals) / len(vals))
    return (m, sd)

def aggregate(run_list):

    rates = [s['rate'] for s in run_list]
    ok_rates = [s['ok_rate'] for s in run_list]
    mibs = [s['mibs'] for s in run_list]
    wins = [s['window_s'] for s in run_list]
    durs = [s['avg'] for s in run_list]
    rm, rsd = _mm(rates)
    om, osd = _mm(ok_rates)
    mm_, msd = _mm(mibs)
    wm, wsd = _mm(wins)
    dm, dsd = _mm(durs)
    tot_n = sum(s['n'] for s in run_list)
    tot_ok = sum(s['ok'] for s in run_list)
    tot_fail = sum(s['fail'] for s in run_list)
    tot_to = sum(s['timeouts'] for s in run_list)
    all_durs = sorted(d for s in run_list for d in s['durs_ms'])
    pool_qrow = [v for s in run_list for v in s['pool_qrow']]
    pool_q = [v for s in run_list for v in s['pool_q']]
    pool_dl = [v for s in run_list for v in s['pool_dl']]
    pool_obt = [v for s in run_list for v in s['pool_obtdur']]
    pool_nh = [v for s in run_list for v in s['pool_nhits']]
    holders = Counter()
    for s in run_list:
        holders.update(s['holders'])
    pqm, psd, pn = pop_mean_sd(all_durs)
    oqm, osdq, oqn = pop_mean_sd(pool_q)
    olm, osdd, oln = pop_mean_sd(pool_dl)
    odm, odsd, odn = pop_mean_sd(pool_obt)
    return {
        'runs': len(run_list),
        'rate_mean': rm, 'rate_sd': rsd,
        'rate_min': min(rates), 'rate_max': max(rates),
        'ok_rate_mean': om, 'ok_rate_sd': osd,
        'mibs': mm_, 'mibs_sd': msd,
        'window_mean': wm, 'window_sd': wsd,
        'min_win': min(wins), 'max_win': max(wins),
        'dur_mean': dm, 'dur_sd': dsd,
        'n': tot_n, 'ok': tot_ok, 'fail': tot_fail, 'timeouts': tot_to,
        'fail_pct': 100.0 * tot_fail / tot_n if tot_n else 0.0,
        'to_pct': 100.0 * tot_to / tot_n if tot_n else 0.0,

        'p50': percentile(all_durs, 0.50), 'p95': percentile(all_durs, 0.95),
        'p99': percentile(all_durs, 0.99), 'max': all_durs[-1],

        'pool_dur_mean': pqm, 'pool_dur_sd': psd, 'pool_n': pn,
        'pool_q_mean': oqm, 'pool_q_sd': osdq, 'pool_q_n': oqn,
        'pool_dl_mean': olm, 'pool_dl_sd': osdd, 'pool_dl_n': oln,
        'pool_obt_mean': odm, 'pool_obt_sd': odsd, 'pool_obt_n': odn,
        'pool_nhits_mean': (sum(pool_nh) / len(pool_nh)) if pool_nh else 0.0,
        'holders': holders,
        'durs_ms': all_durs,
    }

def load_cpu_samples(root):

    out = {}
    for topo in TOPOS:
        rows = []
        for p in sorted(glob.glob(os.path.join(root, topo, 'cpu-e2-vm*.txt'))):
            m = re.search(r'cpu-e2-vm0*(\d+)\.txt$', p)
            if not m:
                continue
            vals = []
            with open(p) as f:
                for line in f:
                    mm = re.match(r'cpu (\d+(?:\.\d+)?)\s*$', line.strip())
                    if mm:
                        vals.append(float(mm.group(1)))
            if not vals:
                continue
            mean = sum(vals) / len(vals)
            rows.append((int(m.group(1)), mean, max(vals), len(vals)))
        if rows:
            out[topo] = sorted(rows)
    return out

STAT_FIELDS = ('routes', 'pending', 'neighbours', 'files',
               'repl_push', 'repl_skip', 'repl_recv',
               'drops_route', 'drops_hit',
               'q_recv', 'q_fwd', 'q_dup', 'h_orig', 'h_relay')

def load_stats_delta(root):

    out = {}
    for topo in TOPOS:
        p = os.path.join(root, topo, 'stats-delta.txt')
        if not os.path.exists(p):
            continue
        per = {}
        with open(p) as f:
            for line in f:
                m = re.match(r'^vm (\d+) ((?:\w+=\d+\s*)+)$', line.strip())
                if not m:
                    continue
                vm = int(m.group(1))
                d = {}
                for kv in m.group(2).split():
                    k, _, v = kv.partition('=')
                    if k in STAT_FIELDS:
                        d[k] = int(v)
                per[vm] = d
        if not per:
            continue
        tot = Counter()
        for d in per.values():
            for k, v in d.items():
                tot[k] += v
        out[topo] = {'tot': tot, 'per': per}
    return out

def main():
    import argparse
    ap = argparse.ArgumentParser(description='PA2 experiment analyzer v3')
    ap.add_argument('--root', default='results')
    ap.add_argument('--verify-dir', default=None)
    ap.add_argument('--out', default=None,
                    help='output dir (default = --root)')
    args = ap.parse_args()
    out = args.out or args.root
    os.makedirs(out, exist_ok=True)
    figdir = os.path.join(out, 'figures')

    runs = gather(args.root, args.verify_dir)
    grouped = defaultdict(list)
    for (topo, exp, run), rfs in sorted(runs.items()):
        s = summarize_run(rfs)
        s['run'] = run
        grouped[(topo, exp)].append(s)

    lines = []
    add = lines.append
    import datetime
    add('PA2 experiment summary - analyzer v3 (shared-window methodology,')
    add('per-op pooled stats, phase split, per-holder downloads, e2 CPU,')
    add('control-plane message deltas from stats-delta.txt)')
    add('generated %s UTC' %
        datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))
    add('throughput = rows / (max(ts_end) - min(ts_start)) across')
    add('all bench processes of a run on ONE wall-clock window; NOT the sum')
    add('of per-process self rates (v1 method, which was invalid).')
    add('cluster cross-VM clock skew measured <= ~1 s; windows are >= 4 s.')
    add('')
    tex_rows = {}
    for (topo, exp), rs in sorted(grouped.items()):
        rs.sort(key=lambda s: s['run'])
        hdr = '=== %s / %s ===' % (topo, exp)
        if exp.startswith('fo-'):
            hdr += ('  [failover DEMO capture -- timing evidence only, NOT '
                    'part of the throughput campaign]')
        add(hdr)
        for s in rs:
            add('  run %d [%d bench procs %s]: %s' %
                (s['run'], s['nproc'], ','.join(s['nodes']), fmt_run(s)))
            if s['seqgaps']:
                add('      NOTE: %d missing seq slots (v1 bench dropped '
                    'failed ops: rows are an under-count of failures)'
                    % s['seqgaps'])
        agg = aggregate(rs)
        add('  AGGREGATE over %d runs: throughput %.1f +/- %.1f q/s '
            '(min %.1f, max %.1f), window %.1f s mean (%.1f-%.1f), '
            'fail %.3f%% (timeouts %.3f%%), lat p50/p95/p99 = %.1f/%.1f/'
            '%.1f ms' %
            (agg['runs'], agg['rate_mean'], agg['rate_sd'], agg['rate_min'],
             agg['rate_max'], agg['window_mean'], agg['min_win'],
             agg['max_win'], agg['fail_pct'], agg['to_pct'],
             agg['p50'], agg['p95'], agg['p99']))
        add('  pooled per-op (all rows, all runs): mean %.2f +/- %.2f ms '
            '(n=%d)' % (agg['pool_dur_mean'], agg['pool_dur_sd'],
                        agg['pool_n']))
        if agg['pool_q_n'] or agg['pool_dl_n']:
            add('    phases: lookup %.2f +/- %.2f ms (n=%d), download '
                '%.2f +/- %.2f ms (n=%d)' %
                (agg['pool_q_mean'], agg['pool_q_sd'], agg['pool_q_n'],
                 agg['pool_dl_mean'], agg['pool_dl_sd'], agg['pool_dl_n']))
        if any(s['obtain_ops'] for s in rs):
            add('  transfer: %.2f MiB/s mean (obtain runs)' % agg['mibs'])
        tex_rows[(topo, exp)] = agg
        add('')

    add('=== throughput ranking (e2 shared-window queries) ===')
    e2 = {t: aggregate(v) for (t, e), v in
          ((k, grouped[k]) for k in grouped if k[1] == 'e2')}
    for t in sorted(e2, key=lambda t: -e2[t]['rate_mean']):
        a = e2[t]
        add('  %-8s %9.1f +/- %6.1f q/s   (fail %.3f%% incl timeouts %.3f%%, '
            'lat p50 %.1f ms)' %
            (t, a['rate_mean'], a['rate_sd'], a['fail_pct'], a['to_pct'],
             a['p50']))
    add('')

    cpu = load_cpu_samples(args.root)
    if cpu:
        add('=== e2 CPU samples (1 Hz /proc/<pid>/stat, whole e2 window) ===')
        add('    central: vm01=index server; star: vm02=hub; '
            'mesh: vm07=interior; all others: bench clients')
        for topo in TOPOS:
            if topo not in cpu:
                continue
            add('  %s:' % topo)
            for vm, mean, mx, ns in cpu[topo]:
                add('    vm%02d: mean %5.1f%%  max %5.1f%%  (%d samples)' %
                    (vm, mean, mx, ns))
        add('')

    st = load_stats_delta(args.root)
    if st:
        add('=== overlay control-plane deltas (ping counters, e1..e4) ===')
        for topo in TOPOS:
            if topo not in st:
                continue
            t = st[topo]['tot']
            ops = sum(agg2['n'] for (tp, e), agg2 in tex_rows.items()
                      if tp == topo and e in ('e1', 'e2', 'e3', 'e4'))
            wire = t['q_fwd'] + t['h_orig'] + t['h_relay']
            add('  %s: ops=%d q_recv=%d q_fwd=%d q_dup=%d h_orig=%d '
                'h_relay=%d route_miss=%d hit_drop=%d repl_push=%d' %
                (topo, ops, t['q_recv'], t['q_fwd'], t['q_dup'],
                 t['h_orig'], t['h_relay'], t['drops_route'],
                 t['drops_hit'], t['repl_push']))
            add('       wire msgs (fwd+hits)/op = %.3f, dup ratio = %.4f' %
                (wire / ops if ops else 0.0,
                 (t['q_dup'] / t['q_recv']) if t['q_recv'] else 0.0))
        add('')

    add('=== e4 downloads served per holder VM ===')
    for topo in TOPOS:
        agg = tex_rows.get((topo, 'e4'))
        if not agg or not agg['holders']:
            continue
        tot = sum(agg['holders'].values())
        items = sorted(agg['holders'].items(), key=lambda kv: -kv[1])
        row = ', '.join('vm%d:%d' % (o - 100, c) for o, c in items)
        mx = items[0][1]
        mn = items[-1][1]
        add('  %-8s %s   (spread %d..%d, n=%d)' % (topo, row, mn, mx, tot))
    add('')

    txt = '\n'.join(lines) + '\n'
    with open(os.path.join(out, 'summary.txt'), 'w') as f:
        f.write(txt)
    sys.stdout.write(txt)

    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        os.makedirs(figdir, exist_ok=True)

        def bar(exp, key, sdkey, ylabel, title, fname, prec=1, log=False):
            ts = [t for t in TOPOS if (t, exp) in tex_rows]
            if not ts:
                return
            means = [tex_rows[(t, exp)][key] for t in ts]
            sds = [tex_rows[(t, exp)][sdkey] if sdkey else 0.0 for t in ts]
            fig, ax = plt.subplots(figsize=(6.4, 4))
            ax.bar(range(len(ts)), means, yerr=sds, capsize=4,
                   color=['#4C72B0', '#DD8452', '#55A868'][:len(ts)])
            ax.set_xticks(range(len(ts)))
            ax.set_xticklabels(ts)
            ax.set_ylabel(ylabel)
            ax.set_title(title)
            top = max(m + s for m, s in zip(means, sds))
            off = 0.04 * top
            for i, m in enumerate(means):

                ax.annotate('%.*f' % (prec, m), (i, m + sds[i] + off),
                            ha='center', va='bottom')
            ax.set_ylim(top=top * 1.18)
            if log:
                ax.set_yscale('log')
            fig.tight_layout()
            fig.savefig(os.path.join(figdir, fname))
            plt.close(fig)

        def bars2(exp_key, series, ylabel, title, fname, prec=1, log=False):

            fig, ax = plt.subplots(figsize=(6.4, 4))
            n = len(series)
            top = 0.0
            for gi, (t) in enumerate(TOPOS):
                for si, (exp, lab, col) in enumerate(series):
                    a = tex_rows.get((t, exp))
                    if not a:
                        continue
                    m, s = a[exp_key], a.get(exp_key + '_sd', 0.0)
                    x = gi + (si - (n - 1) / 2.0) * 0.35
                    ax.bar(x, m, 0.35, yerr=s, capsize=3, color=col,
                           label=('%s %s' % (lab, t)) if si == 0 else None,
                           edgecolor='white')
                    top = max(top, m + s)
                    ax.annotate('%.*f' % (prec, m), (x, m + s + 0.04 * top),
                                ha='center', va='bottom', fontsize=8)
            ax.set_xticks(range(len(TOPOS)))
            ax.set_xticklabels(TOPOS)
            ax.set_ylabel(ylabel)
            ax.set_title(title)
            ax.legend(fontsize=8)
            if log:
                ax.set_yscale('log')
            else:
                ax.set_ylim(top=top * 1.18)
            fig.tight_layout()
            fig.savefig(os.path.join(figdir, fname))
            plt.close(fig)

        bar('e1', 'dur_mean', 'dur_sd', 'mean latency (ms)',
            'e1: query latency, 1 client (mean $\\pm$ sd over runs)',
            'fig_e1.png')
        bar('e2', 'rate_mean', 'rate_sd', 'queries/s (shared window)',
            'e2: 9-client query throughput (mean $\\pm$ sd over runs)',
            'fig_e2.png')
        bar('e3', 'rate_mean', 'rate_sd', 'obtains/s (shared window)',
            'e3: small-file obtain rate, 9 clients', 'fig_e3_rate.png')
        bar('e3', 'mibs', 'mibs_sd', 'MiB/s (shared window)',
            'e3: small-file goodput, 9 clients', 'fig_e3_mibs.png')
        bar('e4', 'mibs', 'mibs_sd', 'MiB/s (shared window)',
            'e4: 100 MB transfer goodput, 9 clients', 'fig_e4.png')

        bars2('mibs', [('e3', 'small (10 kB)', '#4C72B0'),
                       ('e4', 'large (100 MB)', '#DD8452')],
              'goodput (MiB/s, log scale)',
              'e3 vs e4: small vs large transfer goodput',
              'fig_e3_vs_e4_log.png', log=True)

        if any(tex_rows.get((t, 'e4'), {}).get('pool_q_n', 0)
               for t in TOPOS):
            def bar_phase():
                ts = [t for t in TOPOS
                      if tex_rows.get((t, 'e4'), {}).get('pool_q_n', 0)]
                if not ts:
                    return
                fig, ax = plt.subplots(figsize=(6.4, 4))
                top = 0.0
                for gi, t in enumerate(ts):
                    a = tex_rows[(t, 'e4')]
                    for si, (key, col, lab) in enumerate(
                            [('pool_q', '#55A868', 'lookup phase'),
                             ('pool_dl', '#DD8452', 'download phase')]):
                        m, s = a[key + '_mean'], a[key + '_sd']
                        x = gi + (si - 0.5) * 0.35
                        ax.bar(x, m, 0.35, yerr=s, capsize=3, color=col,
                               edgecolor='white')
                        top = max(top, m + s)
                        ax.annotate('%.1f' % m, (x, m + s + 0.04 * top),
                                    ha='center', va='bottom', fontsize=8)
                ax.set_xticks(range(len(ts)))
                ax.set_xticklabels(ts)
                ax.set_ylabel('per-op mean$\\pm$sd (ms, pooled rows)')
                ax.set_title('e4: lookup vs download phase (pooled over all '
                             'obtain rows of all runs)')
                ax.legend(['lookup phase', 'download phase'], fontsize=8)
                ax.set_ylim(top=top * 1.18)
                fig.tight_layout()
                fig.savefig(os.path.join(figdir, 'fig_e4_split.png'))
                plt.close(fig)
            bar_phase()

        for exp in ('e1', 'e2'):
            if not any((t, exp) in tex_rows for t in TOPOS):
                continue
            fig, ax = plt.subplots(figsize=(6.4, 4))
            for topo, col in zip(TOPOS, ('#4C72B0', '#DD8452', '#55A868')):
                a = tex_rows.get((topo, exp))
                if not a:
                    continue
                d = a['durs_ms']
                xs = [v if v > 0 else 1e-2 for v in d]
                ys = [(i + 0.5) / len(d) for i in range(len(d))]
                ax.plot(xs, ys, color=col,
                        label='%s (n=%d)' % (topo, len(d)))
            ax.set_xscale('log')
            ax.set_yscale('linear')
            ax.set_xlabel('op latency (ms, log scale)')
            ax.set_ylabel('CDF (pooled over all runs)')
            ax.set_title('%s latency CDF, all three topologies' % exp)
            ax.legend(fontsize=8)
            fig.tight_layout()
            fig.savefig(os.path.join(figdir, 'fig_cdf_%s.png' % exp))
            plt.close(fig)
        print('figures written to %s' % figdir)
    except ImportError:
        print('matplotlib not available: figures skipped')

    EXP_ROWS = {
        'e1': [
            ('shared window (s)', 'window_mean', None, 1),
            ('latency mean$\\pm\\sigma$ (ms)$^{\\dagger}$', 'dur_mean',
             'dur_sd', 2),
            ('pooled per-op mean$\\pm\\sigma$ (ms)', 'pool_dur_mean',
             'pool_dur_sd', 2),
            ('latency p50 (ms)', 'p50', None, 2),
            ('latency p95 (ms)', 'p95', None, 2),
            ('latency p99 (ms)', 'p99', None, 2),
            ('failed ops (\\%)', 'fail_pct', None, 3),
        ],
        'e2': [
            ('throughput mean$\\pm\\sigma$ (q/s)',
             'rate_mean', 'rate_sd', 1),
            ('shared window (s)', 'window_mean', None, 1),
            ('pooled per-op mean$\\pm\\sigma$ (ms)', 'pool_dur_mean',
             'pool_dur_sd', 2),
            ('latency p50 (ms)', 'p50', None, 2),
            ('latency p95 (ms)', 'p95', None, 2),
            ('latency p99 (ms)', 'p99', None, 2),
            ('failed ops (\\%)', 'fail_pct', None, 3),
        ],
        'e3': [
            ('obtain rate mean$\\pm\\sigma$ (1/s)',
             'rate_mean', 'rate_sd', 1),
            ('goodput mean$\\pm\\sigma$ (MiB/s)', 'mibs', 'mibs_sd', 1),
            ('pooled per-op mean$\\pm\\sigma$ (ms)', 'pool_dur_mean',
             'pool_dur_sd', 2),
            ('  lookup phase (ms)', 'pool_q_mean', 'pool_q_sd', 2),
            ('  download phase (ms)', 'pool_dl_mean', 'pool_dl_sd', 2),
            ('latency p50 (ms)', 'p50', None, 2),
            ('latency p95 (ms)', 'p95', None, 2),
            ('latency p99 (ms)', 'p99', None, 2),
            ('failed ops (\\%)', 'fail_pct', None, 3),
        ],
        'e4': [
            ('per-op time mean$\\pm\\sigma$ (ms)$^{\\dagger}$', 'dur_mean',
             'dur_sd', 1),
            ('goodput mean$\\pm\\sigma$ (MiB/s)', 'mibs', 'mibs_sd', 1),
            ('pooled per-op mean$\\pm\\sigma$ (ms)', 'pool_dur_mean',
             'pool_dur_sd', 2),
            ('  lookup phase (ms)', 'pool_q_mean', 'pool_q_sd', 2),
            ('  download phase (ms)', 'pool_dl_mean', 'pool_dl_sd', 2),
            ('shared window (s)', 'window_mean', None, 1),
            ('failed ops (\\%)', 'fail_pct', None, 3),
        ],
    }

    def pmf(a, key, sdkey, prec):
        if a is None or a.get(key) is None:
            return '--'
        if sdkey and a.get('runs', 1) > 1:
            return r'$%.*f \pm %.*f$' % (prec, a[key], prec, a[sdkey])
        return r'$%.*f$' % (prec, a[key])

    for a in tex_rows.values():
        if a.get('pool_q_n', 0) == 0:
            a['pool_q_mean'] = a['pool_q_sd'] = None
        if a.get('pool_dl_n', 0) == 0:
            a['pool_dl_mean'] = a['pool_dl_sd'] = None

    with open(os.path.join(out, 'summary.tex'), 'w') as f:
        f.write('% generated by scripts/analyzer.py v3 -- LaTeX booktabs\n')
        f.write('% tabulars, one per experiment; \\input from the report.\n')
        f.write('% DO NOT EDIT: regenerate with analyzer.py instead.\n')
        for exp in ('e1', 'e2', 'e3', 'e4'):
            rows = EXP_ROWS[exp]
            per_exp = []
            per_exp.append('\\begin{tabular}{lccc}\n\\toprule\n')
            per_exp.append('metric & central & star & mesh\\\\\n\\midrule\n')
            for label, key, sdkey, prec in rows:
                cells = ' & '.join(pmf(tex_rows.get((t, exp)), key, sdkey,
                                       prec) for t in TOPOS)
                per_exp.append('%s & %s\\\\\n' % (label, cells))
            per_exp.append('\\bottomrule\n\\end{tabular}\n')
            f.write(''.join(per_exp) + '\n')
            with open(os.path.join(out, 'summary-%s.tex' % exp), 'w') as g:
                g.write('%% analyzer.py v3: %s (mean+/-sd over runs unless\n'
                        '%% marked pooled; latency percentiles include\n'
                        '%% failed/timed-out ops)\n' % exp)
                g.write(''.join(per_exp))

    with open(os.path.join(out, 'summary-e4split.tex'), 'w') as f:
        f.write('% analyzer.py v3: e4 obtain phase breakdown (task 5a/5b).\n')
        f.write('% lookup+download phases are SERVENT-side timings summed\n')
        f.write('% over the successful obtain rows of all e4 runs; pooled\n')
        f.write('% mean +/- population sd over rows. The per-op totals are\n')
        f.write('% the bench-side wall time (includes connection setup).\n')
        f.write('\\begin{tabular}{lccc}\n\\toprule\n')
        f.write('e4 metric & central & star & mesh\\\\\n\\midrule\n')
        for label, key, prec in (
                ('pooled lookup phase mean (ms)', 'pool_q_mean', 2),
                ('pooled download phase mean (ms)', 'pool_dl_mean', 2),
                ('pooled per-op total mean (ms)', 'pool_dur_mean', 2)):
            cells = ' & '.join(
                ('$%.*f$' % (prec, tex_rows[(t, 'e4')][key]))
                if tex_rows.get((t, 'e4'), {}).get(key) is not None else '--'
                for t in TOPOS)
            f.write('%s & %s\\\\\n' % (label, cells))
        f.write('lookup phase share (\\%) & ')
        shares = []
        for t in TOPOS:
            a = tex_rows.get((t, 'e4'))
            if (a and a.get('pool_dl_n') and a.get('pool_q_mean') is not None):
                tot = a['pool_q_mean'] + a['pool_dl_mean']
                shares.append('$%.1f$' % (100.0 * a['pool_q_mean'] / tot))
            else:
                shares.append('--')
        f.write(' & '.join(shares) + '\\\\\n')
        f.write('\\bottomrule\n\\end{tabular}\n')
    print('wrote summary-e4split.tex')

    with open(os.path.join(out, 'summary-e4holders.tex'), 'w') as f:
        f.write('% analyzer.py v3: e4 downloads served per holder VM, from\n')
        f.write('% the v3 holder_ip column (serving VM = last octet - 100).\n')
        f.write('% One tabular per topology; rows sorted by serve count.\n')
        for topo in TOPOS:
            a = tex_rows.get((topo, 'e4'))
            if not a or not a['holders']:
                continue
            tot = sum(a['holders'].values())
            items = sorted(a['holders'].items(), key=lambda kv: (-kv[1],
                                                                kv[0]))
            f.write('\n%% %s e4: %d downloads, served spread %d..%d\n' %
                    (topo, tot, items[-1][1], items[0][1]))
            f.write('\\begin{tabular}{lrr}\n\\toprule\n')
            f.write('holder & downloads & share \\\\\n\\midrule\n')
            for o, c in items:
                f.write('vm%02d & %d & %.1f%% \\\\\n' %
                        (o - 100, c, 100.0 * c / tot))
            f.write('\\bottomrule\n\\end{tabular}\n')
    print('wrote summary-e4holders.tex')

    with open(os.path.join(out, 'summary-cpu.tex'), 'w') as f:
        f.write('% analyzer.py v3: e2-window CPU (1 Hz /proc stat deltas;\n')
        f.write('% sampler set: critical relay process + 2 bench clients.\n')
        f.write('% central vm01=index, star vm02=hub, mesh vm07=interior.)\n')
        f.write('\\begin{tabular}{lcccc}\n\\toprule\n')
        f.write('process & central & star & mesh & \\\\\n')
        f.write('\\midrule\n')
        seen = set()
        for topo in TOPOS:
            for vm, mean, mx, ns in cpu.get(topo, []):
                seen.add(vm)
        rowno = 0
        for vm in sorted(seen):
            cells = []
            for topo in TOPOS:
                hit = [r for r in cpu.get(topo, []) if r[0] == vm]
                cells.append('$%.1f$ (max $%.1f$)' % (hit[0][1], hit[0][2])
                             if hit else '--')
            f.write('vm%02d & %s\\\\\n' % (vm, ' & '.join(cells)))
            rowno += 1
        f.write('\\bottomrule\n\\end{tabular}\n')
        f.write('% cell format: mean% (max%) over the e2 bench window\n')
    print('wrote summary-cpu.tex')

    if st:
        ops_per = {}
        for (tp, e), a in tex_rows.items():
            if e in ('e1', 'e2', 'e3', 'e4'):
                ops_per[tp] = ops_per.get(tp, 0) + a['n']
        with open(os.path.join(out, 'summary-msgs.tex'), 'w') as f:
            f.write('% analyzer.py v3: overlay control-plane counters summed\n'
                    '% over all 17 servents, deltas across the e1..e4 bench\n'
                    '% sets (ping snapshots before e1 / after e4).\n')
            f.write('\\begin{tabular}{lccc}\n\\toprule\n')
            f.write('counter & central & star & mesh\\\\\n\\midrule\n')
            for label, key in (
                    ('queries received (q recv)', 'q_recv'),
                    ('query floods forwarded (q fwd)', 'q_fwd'),
                    ('duplicate queries dropped (q dup)', 'q_dup'),
                    ('hit answers generated local (h orig)', 'h_orig'),
                    ('hit hops relayed (h relay)', 'h_relay'),
                    ('route-miss drops', 'drops_route'),
                    ('hit-coll drops', 'drops_hit'),
                    ('replication pushes', 'repl_push')):
                cells = ' & '.join(
                    ('{:,}'.format(st[t]['tot'][key])
                     if t in st else '--') for t in TOPOS)
                f.write('%s & %s\\\\\n' % (label, cells))
            cells = ' & '.join('{:,}'.format(ops_per.get(t, 0))
                               if t in st else '--' for t in TOPOS)
            f.write('bench ops (e1$\\ldots$e4 totals) & %s\\\\\n' % cells)
            cells = ' & '.join(
                ('%.2f' % ((st[t]['tot']['q_fwd'] + st[t]['tot']['h_orig'] +
                            st[t]['tot']['h_relay']) / ops_per[t]))
                if (t in st and ops_per.get(t)) else '--' for t in TOPOS)
            f.write('wire msgs per bench op & %s\\\\\n' % cells)
            f.write('\\bottomrule\n\\end{tabular}\n')
        print('wrote summary-msgs.tex')

    EMAP = {'e1': 'Eone', 'e2': 'Etwo', 'e3': 'Ethree', 'e4': 'Efour'}
    TMAP = {'central': 'Central', 'star': 'Star', 'mesh': 'Mesh'}

    def texnum(v, prec):
        s = '%.*f' % (prec, v)
        if abs(v) < 1000:
            return s
        neg = s.startswith('-')
        intpart, dot, frac = (s[1:] if neg else s).partition('.')
        groups = []
        while len(intpart) > 3:
            groups.insert(0, intpart[-3:])
            intpart = intpart[:-3]
        out2 = '{,}'.join([intpart] + groups)
        if dot:
            out2 += '.' + frac
        return ('-' + out2) if neg else out2

    DEF_METRICS = [
        ('Rate', 'rate_mean', 'rate_sd', 1),
        ('Window', 'window_mean', None, 1),
        ('Dur', 'dur_mean', 'dur_sd', 2),
        ('Mibs', 'mibs', 'mibs_sd', 1),
        ('Pfifty', 'p50', None, 2),
        ('Pnintyfive', 'p95', None, 2),
        ('Pnintynine', 'p99', None, 2),
        ('Fail', 'fail_pct', None, 3),
        ('To', 'to_pct', None, 3),
        ('PoolDur', 'pool_dur_mean', 'pool_dur_sd', 2),
        ('PoolQ', 'pool_q_mean', 'pool_q_sd', 2),
        ('PoolDl', 'pool_dl_mean', 'pool_dl_sd', 2),
    ]

    with open(os.path.join(out, 'summary-defs.tex'), 'w') as f:
        f.write('% generated by scripts/analyzer.py v3 -- report prose\n')
        f.write('% macros. DO NOT EDIT. Usage: \\vEtwoRateMesh\\ etc.\n')
        for exp in ('e1', 'e2', 'e3', 'e4'):
            for metric, key, sdkey, prec in DEF_METRICS:
                for topo in TOPOS:
                    a = tex_rows.get((topo, exp))
                    if a is None or a.get(key) is None:
                        continue
                    name = 'v%s%s%s' % (EMAP[exp], metric, TMAP[topo])
                    if sdkey and a.get('runs', 1) > 1:
                        val = '%s \\pm %s' % (texnum(a[key], prec),
                                              texnum(a[sdkey], prec))
                    else:
                        val = texnum(a[key], prec)
                    f.write('\\def\\%s{%s}\n' % (name, val))
    print('wrote summary-defs.tex (report prose macros)')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
