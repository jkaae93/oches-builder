"""Offline Agent-only template graph experiment; no registry, provider or execution."""
from collections import defaultdict, deque
from jsonschema import Draft202012Validator
from check_agent_definition import SCHEMA as AGENT_SCHEMA, check as check_agent

ID = {'type': 'string', 'minLength': 1, 'maxLength': 128, 'pattern': '^[A-Za-z0-9][A-Za-z0-9._:-]*$'}
PORT_REF = {'type':'object','additionalProperties':False,'required':['node','port'],'properties':{'node':ID,'port':ID}}
GRAPH_SCHEMA = {
    '$schema':'https://json-schema.org/draft/2020-12/schema',
    'type':'object', 'additionalProperties':False,
    'required':['schemaVersion','nodes','edges'],
    'properties': {
        'schemaVersion':{'type':'object','additionalProperties':False,'required':['major','minor'],'properties':{'major':{'const':1},'minor':{'const':0}}},
        'nodes':{'type':'array','minItems':1,'maxItems':1024,'items':{
            'type':'object','additionalProperties':False,'required':['id','kind','definition'],
            'properties':{'id':ID,'kind':{'const':'agent'},'definition':AGENT_SCHEMA, 'externalInputs':{'type':'array','uniqueItems':True,'maxItems':128,'items':ID}}}},
        'edges':{'type':'array','maxItems':4096,'items':{
            'type':'object','additionalProperties':False,'required':['from','to'],
            'properties':{'from':PORT_REF,'to':PORT_REF}}}
    }
}
Draft202012Validator.check_schema(GRAPH_SCHEMA)
GRAPH_VALIDATOR = Draft202012Validator(GRAPH_SCHEMA)

def check_graph(graph):
    errors=[e.message for e in GRAPH_VALIDATOR.iter_errors(graph)]
    if errors: return errors
    nodes={n['id']:n for n in graph['nodes']}
    if len(nodes)!=len(graph['nodes']): return ['duplicate node ID']
    for node in graph['nodes']:
        errors.extend(f"{node['id']}: {e}" for e in check_agent(node['definition']))
    if errors: return errors
    adjacency=defaultdict(list); indegree={node:0 for node in nodes}; incoming=set()
    for edge in graph['edges']:
        source=edge['from']; target=edge['to']
        if source['node'] not in nodes or target['node'] not in nodes:
            errors.append('missing node'); continue
        src={p['portId']:p for p in nodes[source['node']]['definition']['outputs']}.get(source['port'])
        dst={p['portId']:p for p in nodes[target['node']]['definition']['inputs']}.get(target['port'])
        if not src or not dst:
            errors.append('missing or wrong-direction port'); continue
        if src['type']!=dst['type']: errors.append('PORT_MISMATCH')
        if src['type']=='json': errors.append('JSON compatibility UNKNOWN')
        key=(target['node'],target['port'])
        if key in incoming: errors.append('multiple incoming sources')
        incoming.add(key)
        adjacency[source['node']].append(target['node']);indegree[target['node']]+=1
    for node in graph['nodes']:
        inputs={p['portId']:p for p in node['definition']['inputs']}
        declared=set(node.get('externalInputs', []))
        if not declared.issubset(inputs):errors.append('external input references missing port')
        for port, spec in inputs.items():
            linked=(node['id'],port) in incoming
            if linked and port in declared:errors.append('external and graph source conflict')
            if spec['required'] and not linked and port not in declared:errors.append('required input missing source')
    queue=deque(k for k,v in indegree.items() if v==0); seen=0
    while queue:
        node=queue.popleft();seen+=1
        for nxt in adjacency[node]:
            indegree[nxt]-=1
            if indegree[nxt]==0:queue.append(nxt)
    if seen!=len(nodes): errors.append('cycle')
    return errors
