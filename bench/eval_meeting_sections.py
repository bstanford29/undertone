"""Metrics-only coverage check of summary batching on private meeting exports.

This checks retained transcript coverage, not summary quality or audio capture.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
from undertone.meeting import MeetingService, MAX_SUMMARY_SECTION_CHARS


def evaluate(directory: Path) -> dict:
    metrics = []
    for path in sorted(directory.glob('*.ndjson')):
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        if any(not isinstance(row.get('text'), str) for row in rows):
            raise ValueError('Meeting row missing text')
        sections = []
        def summarize(value: str) -> str:
            if value != 'Summary.' and not value.startswith('Summary.\n'):
                sections.append(value)
            return 'Summary.'
        with tempfile.TemporaryDirectory(prefix='undertone-meeting-eval-') as temporary:
            root = Path(temporary)
            service = MeetingService(root/'meeting.sqlite', root/'audio', summarize=summarize)
            session_id = service.start('Private coverage fixture')['session_id']
            with service._connect() as db:
                for index, row in enumerate(rows):
                    db.execute('INSERT INTO meeting_chunks(session_id,seq,source_path,retained_path,speaker,offset_s,duration_s,status,text,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)', (session_id,index,'unused','unused','others',float(index),1,'complete',row['text'],0))
            service._make_summary(session_id)
        expected = '\n'.join(f"[{float(index):.3f}] others: {row['text']}" for index,row in enumerate(rows))
        preserved = ''.join(expected.split()) == ''.join(''.join(sections).split())
        metrics.append({'rows':len(rows), 'sections':len(sections), 'content_preserved':preserved, 'bounded':all(len(s)<=MAX_SUMMARY_SECTION_CHARS for s in sections)})
    return {'meetings':len(metrics),'rows':sum(m['rows'] for m in metrics),'all_content_preserved':bool(metrics) and all(m['content_preserved'] for m in metrics),'all_sections_bounded':bool(metrics) and all(m['bounded'] for m in metrics),'details':metrics,'limitation':'Synthetic summarizer checks batching coverage only; no summary-quality or real-call claim.'}

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--meetings',required=True,type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args(); result=evaluate(args.meetings)
    output=json.dumps(result,indent=2)
    if args.output:args.output.write_text(output)
    print(output)
