import importlib.util
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location('luna_ssh', Path(__file__).resolve().parents[1] / 'luna_ssh.py')
luna = importlib.util.module_from_spec(spec)
spec.loader.exec_module(luna)


class LunaSshTests(unittest.TestCase):
    def test_input_stays_open_until_asynchronous_reply(self):
        child = '''import json,select,sys
if select.select([sys.stdin],[],[],0.05)[0]:
 sys.exit(1)
print(json.dumps({'returnValue':True}),flush=True)
sys.stdin.read()
'''
        self.assertEqual(luna.exchange([sys.executable, '-c', child], timeout=2), [{'returnValue': True}])

    def test_install_success_precedes_subscription_disconnect(self):
        child = '''import json,sys
for response in [{'returnValue':True},{'details':{'state':'installed'}},
                 {'returnValue':False,'errorText':'install has been disconnected.'}]:
 print(json.dumps(response),flush=True)
sys.stdin.read()
'''
        replies = luna.exchange([sys.executable, '-c', child], timeout=2, until='installed')
        self.assertEqual(replies[-1]['details']['state'], 'installed')
        self.assertEqual(len(replies), 2)

    def test_failure_before_terminal_state_is_not_success(self):
        child = "import json;print(json.dumps({'returnValue':False,'errorText':'install denied'}),flush=True)"
        with self.assertRaisesRegex(RuntimeError, 'install denied'):
            luna.exchange([sys.executable, '-c', child], timeout=2, until='installed')


if __name__ == '__main__':
    unittest.main()
