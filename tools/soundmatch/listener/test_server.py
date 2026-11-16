"""Persistence and blind-serving contract; all labels use a temporary directory."""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request,urlopen
from server import Server

class ListeningServerTest(unittest.TestCase):
    def test_session_audio_validation_and_persistence(self):
        with tempfile.TemporaryDirectory() as directory:
            server=Server(0,Path(directory));thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            base=f'http://127.0.0.1:{server.server_port}'
            def request(path,data=None,headers=None):
                with urlopen(Request(base+path,data=json.dumps(data).encode() if data is not None else None,headers=headers or {})) as response:return response.read()
            try:
                session=json.loads(request('/api/session'));self.assertEqual(len(session['trials']),6);self.assertEqual(session['labels'],{})
                raw=json.dumps(session);self.assertNotIn('refined',raw);self.assertNotIn('initial.wav',raw);self.assertNotIn('/Users',raw)
                trial=session['trials'][0];self.assertTrue(request(trial['audio']['A']).startswith(b'RIFF'))
                for path in ['/blind-key.json','/../server.py','/audio/not-found']:
                    with self.assertRaises(HTTPError) as error:request(path)
                    self.assertEqual(error.exception.code,404);error.exception.close()
                for payload in [{'id':trial['id'],'choice':'invalid'},{'id':'invalid','choice':'A'}]:
                    with self.assertRaises(HTTPError) as error:request('/api/label',payload)
                    self.assertEqual(error.exception.code,400);error.exception.close()
                with self.assertRaises(HTTPError) as error:request('/api/label',{'id':trial['id'],'choice':'A'},{'Origin':'https://example.com'})
                self.assertEqual(error.exception.code,403);error.exception.close()
                for choice in ['A','B','tie','skip']:
                    result=json.loads(request('/api/label',{'id':trial['id'],'choice':choice,'heard':['reference','A','B']}))
                    self.assertEqual(result['labels'][trial['id']]['choice'],choice)
                    self.assertEqual(json.loads(server.state_file.read_text()),result['labels'])
                exported=json.loads(request('/api/export'));self.assertEqual(exported['labels'],result['labels'])
                replacement=Server(0,Path(directory));self.assertEqual(replacement.labels,result['labels']);replacement.server_close()
                result=json.loads(request('/api/label',{'id':trial['id'],'choice':None}));self.assertEqual(result['labels'],{})
            finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
