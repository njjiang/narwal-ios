#!/usr/bin/env python3
"""Check Siri/Shortcuts registration in an actual xcodebuild-produced .app.

Usage: python3 Tests/verify_shortcut_metadata.py /path/to/Narwal.app
This checks exported presentation, not Siri recognition or the OS's live cache.
"""
import json
from pathlib import Path
import sys


def verify(bundle: Path, *, exact_phrases: bool = False) -> None:
    if not exact_phrases:
        language_asset = bundle / 'Metadata.appintents/nlu/nlu.lzfse'
        assert language_asset.is_file() and language_asset.stat().st_size > 0, \
            'Siri language assets are missing even if xcodebuild reported success'
    metadata = json.loads((bundle / 'Metadata.appintents/extract.actionsdata').read_text())
    shortcuts = metadata['autoShortcuts']
    by_action = {entry['actionIdentifier']: entry for entry in shortcuts}
    expected = {
        'VacuumRoomIntent': 'vacuum', 'MopRoomIntent': 'mop',
        'VacuumAndMopRoomIntent': 'vacuum and mop',
        'VacuumThenMopRoomIntent': 'vacuum then mop',
    }
    expected_controls = {
        'PauseRobotIntent': 'Pause ${applicationName}',
        'StopRobotIntent': 'Stop ${applicationName}',
    }
    assert len(shortcuts) == 6 and set(by_action) == (set(expected) | set(expected_controls)), \
        'Expected four mode-specific registrations plus pause and stop'
    for action, verb in expected.items():
        entry = by_action[action]
        assert 'parameterPresentation' not in entry, 'Do not duplicate automatic entity tiles with an options collection'
        assert metadata['actions'][action].get('openAppWhenRun', False) is False, 'Room shortcuts must not require unlocking/opening the app'
        parameters = metadata['actions'][action]['parameters']
        assert len(parameters) == 1 and parameters[0]['name'] == 'room', 'A fixed-mode action must accept only its room'
        assert parameters[0]['valueType']['entity']['wrapper']['typeName'] == 'FreoRoomEntity', 'Room must use the live entity catalog'
        phrases = [phrase['key'] for phrase in entry['phraseTemplates']]
        assert 'Run ${applicationName} ' + verb + ' ${room}' in phrases, 'Explicit mode and room phrase missing'
    for action, phrase in expected_controls.items():
        entry = by_action[action]
        assert metadata['actions'][action].get('openAppWhenRun', False) is False, 'Pause and stop shortcuts must not require unlocking/opening the app'
        assert metadata['actions'][action].get('parameters', []) == [], 'Pause and stop shortcuts take no parameters'
        phrases = [item['key'] for item in entry['phraseTemplates']]
        assert phrase in phrases, f'Expected control phrase {phrase} missing'
    mode_enum = next(item for item in metadata['enums'] if item['identifier'] == 'FreoIntentCleaningMode')
    assert {case['identifier'] for case in mode_enum['cases']} == {'vacuum', 'mop', 'vacuumMop', 'vacuumThenMop'}, 'Mode export changed'
    print('Shortcut metadata checks passed: four fixed-mode actions, pause/stop actions, dynamic room parameters, full trigger phrases.')


if __name__ == '__main__':
    exact = '--exact-phrases' in sys.argv[1:]
    arguments = [argument for argument in sys.argv[1:] if argument != '--exact-phrases']
    if len(arguments) != 1:
        raise SystemExit(__doc__)
    verify(Path(arguments[0]), exact_phrases=exact)
