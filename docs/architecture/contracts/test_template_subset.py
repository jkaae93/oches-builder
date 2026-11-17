import copy
import unittest
from check_template_subset import check_graph
from test_agent_definition import BASE

def graph():
    a=copy.deepcopy(BASE); b=copy.deepcopy(BASE)
    a['definitionId']='a';b['definitionId']='b'
    a['outputs']=[{'portId':'out','type':'text','required':True}]
    b['inputs']=[{'portId':'in','type':'text','required':True}]
    return {'schemaVersion':{'major':1,'minor':0},'nodes':[{'id':'a','kind':'agent','definition':a},{'id':'b','kind':'agent','definition':b}], 'edges':[{'from':{'node':'a','port':'out'},'to':{'node':'b','port':'in'}}]}

class GraphTests(unittest.TestCase):
    def test_valid(self): self.assertEqual([],check_graph(graph()))
    def test_required_external_input_declaration(self):
        x=graph();x['edges']=[];x['nodes'][1]['externalInputs']=['in']
        self.assertEqual([],check_graph(x))
    def test_fail_closed_cases(self):
        variants=[]
        x=graph();x['edges']=[];variants.append(x)
        x=graph();x['nodes'][1]['externalInputs']=['unknown'];variants.append(x)
        x=graph();x['nodes'][1]['externalInputs']=['in'];variants.append(x)
        x=graph();x['nodes'][1]['id']='a';variants.append(x)
        x=graph();x['edges'][0]['from']['node']='missing';variants.append(x)
        x=graph();x['edges'][0]['from']['port']='missing';variants.append(x)
        x=graph();x['nodes'][1]['definition']['inputs'][0]['type']='artifactRef';variants.append(x)
        x=graph();x['edges'].append(copy.deepcopy(x['edges'][0]));variants.append(x)
        x=graph();x['schemaVersion']={'major':9,'minor':0};variants.append(x)
        x=graph();x['schemaVersion']='1.0';variants.append(x)
        x=graph();x['nodes'][0]['kind']='tool';variants.append(x)
        x=graph();x['nodes'][0]['definition']['outputs'][0]['type']='json';x['nodes'][1]['definition']['inputs'][0]['type']='json';variants.append(x)
        x=graph();x['nodes'][0]['definition']['inputs']=[{'portId':'in','type':'text','required':True}];x['nodes'][1]['definition']['outputs']=[{'portId':'out','type':'text','required':True}];x['edges'].append({'from':{'node':'b','port':'out'},'to':{'node':'a','port':'in'}});variants.append(x)
        for x in variants:
            with self.subTest(x=x):self.assertTrue(check_graph(x))

if __name__=='__main__': unittest.main(verbosity=2)
