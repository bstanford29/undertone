"""Write a launchd plist for review; never install or activate a service."""
from __future__ import annotations
import argparse
import plistlib
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    python = args.python.absolute()
    if not python.is_file():
        parser.error('Python executable does not exist')
    root = Path(__file__).resolve().parents[1]
    payload = {
        'Label': 'com.undertone.engine',
        'ProgramArguments': [str(python), '-m', 'undertone.cli', 'serve'],
        'WorkingDirectory': str(root),
        'EnvironmentVariables': {'PYTHONPATH': str(root / 'engine'), 'HF_HUB_OFFLINE': '1'},
        'RunAtLoad': True,
        'KeepAlive': True,
        'ThrottleInterval': 10,
        'ProcessType': 'Interactive',
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('wb') as output:
        plistlib.dump(payload, output)
    print(f'Prepared only; not loaded: {args.output}')


if __name__ == '__main__':
    main()
