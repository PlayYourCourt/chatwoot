#!/usr/bin/env python3
"""Pushes deploy/n8n/workflows/*.json into an n8n instance through its REST API and activates them.

  N8N_URL=http://localhost:5678 N8N_EMAIL=… N8N_PASSWORD=… deploy/n8n/push.py [workflow name …]

Workflows are matched by name (created when missing, updated in place otherwise, so ids and webhook URLs are
stable). Credentials referenced by name+type in the JSON are mapped to this instance's credential ids, Execute
Workflow nodes are pointed at the sub-workflow with the given name, and every workflow gets `Seq: error handler`
as its error workflow. Flow workflows that were edited in the editor are only overwritten if named explicitly.
"""
import glob
import json
import os
import sys
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

URL = os.environ.get('N8N_URL', 'http://localhost:5678').rstrip('/')
ORDER = ['Seq: error handler', 'Seq: check api key', 'Seq: Gate', 'Seq: Send', 'Seq: enroll contact']
ERROR_WORKFLOW = 'Seq: error handler'

opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))


def call(method, path, body=None, fatal=True):
    req = urllib.request.Request(f'{URL}/rest{path}', method=method, headers={'Content-Type': 'application/json'},
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with opener.open(req) as res:
            return json.load(res).get('data')
    except urllib.error.HTTPError as e:
        message = f'{method} {path} -> {e.code}: {e.read().decode()[:300]}'
        if fatal:
            sys.exit(message)
        print('  ' + message)
        return None


def main():
    email, password = os.environ.get('N8N_EMAIL'), os.environ.get('N8N_PASSWORD')
    if not (email and password):
        sys.exit('set N8N_EMAIL and N8N_PASSWORD')
    call('POST', '/login', {'emailOrLdapLoginId': email, 'password': password})

    creds = {(c['name'], c['type']): c['id'] for c in call('GET', '/credentials')}
    existing = {w['name']: w for w in call('GET', '/workflows')}
    files = {}
    for path in glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'workflows', '*.json')):
        with open(path) as f:
            wf = json.load(f)
        files[wf['name']] = wf
    def edited(name):  # a flow that exists with content belongs to the editor
        return name.startswith('Flow: ') and name in existing and call('GET', f'/workflows/{existing[name]["id"]}')['nodes']
    wanted = sys.argv[1:] or [n for n in files if not edited(n)]
    skipped = [] if sys.argv[1:] else [n for n in files if n not in wanted]
    if skipped:
        print('kept (edited in the editor; name it to overwrite):', ', '.join(skipped))
    names = sorted(wanted, key=lambda n: (ORDER.index(n) if n in ORDER else len(ORDER), n))

    # pass 1: make sure every workflow exists so sub-workflow references can be resolved
    ids = {n: w['id'] for n, w in existing.items()}
    for name in names:
        if name not in ids:
            created = call('POST', '/workflows', {'name': name, 'nodes': [], 'connections': {}, 'settings': files[name]['settings'], 'active': False})
            ids[name] = created['id']
            print(f'created {name} ({ids[name]})')

    # pass 2: push the real content, then activate
    for name in names:
        wf = files[name]
        for node in wf['nodes']:
            for ctype, cred in node.get('credentials', {}).items():
                key = (cred['name'], ctype)
                if key not in creds:
                    sys.exit(f'{name}: credential {cred["name"]} ({ctype}) does not exist in n8n; create it first')
                cred['id'] = creds[key]
            if node['type'] == 'n8n-nodes-base.executeWorkflow':
                target = node['parameters']['workflowId']['cachedResultName']
                if target not in ids:
                    sys.exit(f'{name}: sub-workflow {target} not found')
                node['parameters']['workflowId']['value'] = ids[target]
        settings = dict(wf['settings'])
        if name != ERROR_WORKFLOW and ERROR_WORKFLOW in ids:
            settings['errorWorkflow'] = ids[ERROR_WORKFLOW]
        current = call('GET', f'/workflows/{ids[name]}')
        body = {'name': name, 'nodes': wf['nodes'], 'connections': wf['connections'], 'settings': settings, 'versionId': current['versionId']}
        updated = call('PATCH', f'/workflows/{ids[name]}', body)
        # n8n 2.x runs the *published* version: publish (activate) the one just saved
        published = call('POST', f'/workflows/{ids[name]}/activate', {'versionId': updated['versionId'], 'name': 'push'}, fatal=False)
        print(f'pushed  {name} ({len(wf["nodes"])} nodes, {"published" if published else "saved, not published"})')


if __name__ == '__main__':
    main()
