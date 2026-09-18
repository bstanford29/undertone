"""Exercise the real local models and socket protocol with isolated history.

Print metrics only. Does not insert text, use the clipboard, install a service,
or write to the user's Undertone history.
"""
from __future__ import annotations
import argparse
import json
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
from undertone import config, dictionary, history
from undertone.server import Engine, Server


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='undertone-proof-') as directory:
        root = Path(directory)
        for module, directory_key, path_key, name in (
            (config, 'CONFIG_DIR', 'CONFIG_PATH', 'config.yaml'),
            (dictionary, 'DICTIONARY_DIR', 'DICTIONARY_PATH', 'dictionary.yaml'),
            (history, 'HISTORY_DIR', 'HISTORY_PATH', 'history.sqlite'),
        ):
            setattr(module, directory_key, root)
            setattr(module, path_key, root / name)
        engine = Engine()
        engine.warm()
        status = engine.dispatch({'op':'status'})
        if status['whisper'] != 'warm' or status['cleanup'] != 'warm':
            raise RuntimeError('Local models could not warm')
        path = root / 'engine.sock'
        server = Server(path, engine)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(120)
                client.connect(str(path))
                stream = client.makefile('rwb')
                sequence = 0
                def request(op, **fields):
                    nonlocal sequence
                    sequence += 1
                    stream.write(json.dumps({'id':sequence,'op':op,**fields}).encode() + b'\n')
                    stream.flush()
                    reply = json.loads(stream.readline())
                    if reply.get('id') != sequence or reply.get('error'):
                        raise RuntimeError('Socket request failed')
                    return reply
                runs = []
                for _ in range(3):
                    started = time.perf_counter()
                    transcript = request('transcribe', audio_path=str(args.file.resolve()), vocab_extra=['Ollama','Qwen'])
                    cleaned = request('clean', raw=transcript['raw'], level='medium', app='com.openai.codex')
                    row = request('history.record', raw_text=transcript['raw'], clean_text=cleaned['clean'],
                                  stt_ms=transcript['stt_ms'], llm_ms=cleaned['llm_ms'], insert_mode='skipped',
                                  guard_fired=cleaned['guard_fired'], model=cleaned['model'], audio_path=str(args.file.resolve()),
                                  app_bundle_id='com.openai.codex')
                    persisted = request('history.last')['row']
                    assert persisted['id'] == row['row_id'] and persisted['clean_text'] == cleaned['clean']
                    assert 'Ollama' in cleaned['clean'] and 'Qwen' in cleaned['clean']
                    assert len(cleaned['clean'].split()) >= .6 * len(transcript['raw'].split())
                    assert '\u2014' not in cleaned['clean']
                    runs.append({'stt_ms':transcript['stt_ms'],'llm_ms':cleaned['llm_ms'],
                                 'loop_ms':(time.perf_counter()-started)*1000,'guard_fired':cleaned['guard_fired']})
                assert len(request('history.list', limit=50)['rows']) == 3
                stream.close()
            import statistics
            print(json.dumps({'status':'PASS','runs':runs,'median_loop_ms':statistics.median(x['loop_ms'] for x in runs),
                              'proper_nouns':True,'history_round_trip':True,'clipboard_used':False}))
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == '__main__':
    main()
