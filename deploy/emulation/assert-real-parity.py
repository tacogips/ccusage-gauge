#!/usr/bin/env python3
"""Aggregate-only exact parity assertions for the required real Docker smoke."""
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal

project, compose, day = sys.argv[1:]
base = ['docker', 'compose', '--project-name', project, '-f', compose]
fixed = f'range=custom&start={day}&end={day}'

def command(service, args):
    return subprocess.check_output(base + ['exec', '-T', service] + args, text=True)

def api(path):
    return json.loads(command('collector', ['curl', '--fail', '--silent', 'http://127.0.0.1:18081' + path]))

def decimal(value):
    return Decimal(str(value))

def totals(data):
    value = data['totals']
    assert isinstance(value['inputTokens'], int) and isinstance(value['outputTokens'], int)
    assert isinstance(value['cacheCreationTokens'], int) and isinstance(value['cacheReadTokens'], int)
    return (decimal(value['costUSD']), value['inputTokens'], value['outputTokens'], value['cacheCreationTokens'], value['cacheReadTokens'])

def session_multiset(data):
    return sorted((
        normalized_timestamp(row['timestamp']), row['agent'], row['model'], row['machine'], str(decimal(row['costUSD'])),
        row['inputTokens'], row['outputTokens'], row['cacheCreationTokens'], row['cacheReadTokens'], row['totalTokens']
    ) for row in data['rows'])

def normalized_timestamp(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)
    return parsed.isoformat(timespec='microseconds').replace('+00:00', 'Z')

def oracle_daily(data, machine):
    return sorted((
        row['period'], agent['agent'], item['modelName'], machine, str(decimal(item['cost'])),
        item['inputTokens'], item['outputTokens'], item['cacheCreationTokens'], item['cacheReadTokens'],
        item['inputTokens'] + item['outputTokens'] + item['cacheCreationTokens'] + item['cacheReadTokens']
    ) for row in data['daily'] for agent in row['agents'] for item in agent['modelBreakdowns'])

def api_daily(data):
    return sorted((
        row['date'], row['agent'], row['model'], row['machine'], str(decimal(row['costUSD'])),
        row['inputTokens'], row['outputTokens'], row['cacheCreationTokens'], row['cacheReadTokens'], row['totalTokens']
    ) for row in data['rows'])

def oracle_sessions(data, machine):
    return sorted((
        normalized_timestamp(row['metadata']['lastActivity']), row['agent'], item['modelName'], machine,
        str(decimal(item['cost'])), item['inputTokens'], item['outputTokens'],
        item['cacheCreationTokens'], item['cacheReadTokens'],
        item['inputTokens'] + item['outputTokens'] + item['cacheCreationTokens'] + item['cacheReadTokens']
    ) for row in data['session'] for item in row['modelBreakdowns'])

def row_totals(rows):
    return (
        sum((decimal(row[4]) for row in rows), Decimal(0)),
        sum(row[5] for row in rows), sum(row[6] for row in rows),
        sum(row[7] for row in rows), sum(row[8] for row in rows)
    )

# Confirm the pinned real binary and app command contract without exposing raw data.
oracles = {}
scoped_data = {}
for scope, service in [('local', 'collector'), ('machine-a', 'machine-a')]:
    assert command(service, ['ccusage', '--version']).splitlines()[0] == 'ccusage 20.0.17'
    oracle = json.loads(command(service, ['ccusage', 'daily', '--json', '--by-agent', '--sections', 'daily,session']))
    assert oracle.get('daily') is not None and oracle.get('session') is not None
    scoped = api(f'/api/metrics?{fixed}&machine={scope}')
    assert scoped['rows'] and all(row['machine'] == scope and row['date'] == day for row in scoped['rows'])
    assert api_daily(scoped) == oracle_daily(oracle, scope)
    oracles[scope] = oracle
    scoped_data[scope] = scoped

local = scoped_data['local']
remote = scoped_data['machine-a']
combined = api(f'/api/metrics?{fixed}&machine=all')
expected_totals = tuple(a + b for a, b in zip(totals(local), totals(remote)))
assert totals(combined)[1:] == expected_totals[1:]
assert abs(totals(combined)[0] - expected_totals[0]) <= Decimal('0.000000000001')
scope = combined['scope']
assert set(scope['includedMachineIds']) >= {'local', 'machine-a', 'machine-b'}
statuses = api('/api/machine-status?machine=all')['machines']
status_summary = [(item['id'], item['collectionState'], item.get('lastError', {}).get('code')) for item in statuses]
assert not scope.get('staleMachineIds') and not scope.get('unavailableMachineIds'), status_summary

# Daily metrics are the daily-series source.  Every sub-daily endpoint must
# return the same unbucketed session multiset, including provenance and tokens.
daily = api(f'/api/cost-series?{fixed}&machine=all&granularity=daily')
assert sorted((row['timestamp'][:10], row['agent'], row['model'], row['machine'], str(decimal(row['costUSD'])), row['inputTokens'], row['outputTokens'], row['cacheCreationTokens'], row['cacheReadTokens'], row['totalTokens']) for row in daily['rows']) == sorted((row['date'], row['agent'], row['model'], row['machine'], str(decimal(row['costUSD'])), row['inputTokens'], row['outputTokens'], row['cacheCreationTokens'], row['cacheReadTokens'], row['totalTokens']) for row in combined['rows'])
session_rows = None
for granularity in ('15min', 'hourly', '6hour'):
    rows = session_multiset(api(f'/api/cost-series?{fixed}&machine=all&granularity={granularity}'))
    assert rows
    if session_rows is None: session_rows = rows
    else: assert rows == session_rows
session_totals = row_totals(session_rows)
assert session_totals[1:] == totals(combined)[1:]
assert abs(session_totals[0] - totals(combined)[0]) <= Decimal('0.000000000001')
assert {row[3] for row in session_rows} == {'local', 'machine-a'}

# A healthy empty machine becomes stale rather than unavailable when stopped,
# then recovers cleanly with no usage rows after restart.
empty = api(f'/api/metrics?{fixed}&machine=machine-b')
assert not empty['rows']
subprocess.check_call(base + ['stop', 'machine-b'], stdout=subprocess.DEVNULL)
time.sleep(1.1)
failed_refresh = subprocess.run(
    base + ['exec', '-T', 'collector', 'curl', '--fail', '--silent', '-H',
            'X-CCUsage-Gauge-Mutation: 1', 'http://127.0.0.1:18081/api/refresh?machine=machine-b'],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
)
assert failed_refresh.returncode != 0
degraded = api(f'/api/metrics?{fixed}&machine=all')['scope']
assert 'machine-b' in degraded.get('staleMachineIds', [])
assert 'machine-b' not in degraded.get('unavailableMachineIds', [])
subprocess.check_call(base + ['start', 'machine-b'], stdout=subprocess.DEVNULL)
public_key = command('keygen', ['cat', '/run/ccusage-keygen/id_ed25519.pub'])
subprocess.run(
    base + ['exec', '-T', 'machine-b', 'sh', '-c',
            'umask 077; cat > /run/ccusage-auth/authorized_keys; chown ccusage:ccusage /run/ccusage-auth/authorized_keys; chmod 0600 /run/ccusage-auth/authorized_keys'],
    input=public_key, text=True, check=True
)
subprocess.check_call(
    base + ['exec', '-T', 'collector', 'rm', '-f', '/run/ccusage-secrets/known_hosts'],
    stdout=subprocess.DEVNULL
)
for _ in range(20):
    subprocess.run(
        base + ['exec', '-T', 'collector', 'curl', '--fail', '--silent', '-H',
                'X-CCUsage-Gauge-Mutation: 1', 'http://127.0.0.1:18081/api/refresh?machine=machine-b'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    recovered = api(f'/api/metrics?{fixed}&machine=all')['scope']
    if not recovered.get('staleMachineIds') and not recovered.get('unavailableMachineIds'):
        break
    time.sleep(0.25)
recovery_status = api('/api/machine-status?machine=machine-b')['machines'][0]
assert not recovered.get('staleMachineIds') and not recovered.get('unavailableMachineIds'), (
    recovery_status['collectionState'], recovery_status.get('lastError')
)
assert not api(f'/api/metrics?{fixed}&machine=machine-b')['rows']
print(json.dumps({'day': day, 'dailyRows': len(combined['rows']), 'sessionRows': len(session_rows)}, sort_keys=True))
