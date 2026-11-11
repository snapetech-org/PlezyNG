#!/usr/bin/env python3
"""AT-SPI client for the installed release app; no application test build needed."""
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import sys

SOCKET = Path(os.environ['XDG_RUNTIME_DIR']) / 'pleazyng-ui-qa.sock'

if len(sys.argv) > 1 and sys.argv[1] == 'request':
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(30)
        client.connect(str(SOCKET))
        client.sendall((json.dumps(sys.argv[2:]) + '\n').encode())
        with client.makefile('rb') as stream:
            result = json.loads(stream.readline(1024 * 1024))
    if 'error' in result:
        raise RuntimeError(result['error'])
    print(json.dumps(result['result']))
    sys.exit(0)

import gi

gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib


def walk(node, depth=0):
    if depth > 32:
        return
    try:
        yield node
        for i in range(node.get_child_count()):
            yield from walk(node.get_child_at_index(i), depth + 1)
    except Exception:
        return


def main():
    desktop = Atspi.get_desktop(0)
    apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    command = sys.argv[1]
    nodes = [node for app in apps if command == 'dump-all' or 'pleazyng' in (app.get_name() or '').lower() for node in walk(app)]
    if command == 'window-state':
        frames = [n for n in nodes if n.get_role_name() == 'frame']
        print(json.dumps([{'active': n.get_state_set().contains(Atspi.StateType.ACTIVE), 'focused': n.get_state_set().contains(Atspi.StateType.FOCUSED)} for n in frames]))
        return
    if command in ('dump', 'dump-all'):
        print(json.dumps([{'name': n.get_name(), 'role': n.get_role_name()} for n in nodes]))
        return
    label = sys.argv[2]
    found = ([n for n in nodes if n.get_role_name() == label] if command == 'fill-role'
             else [n for n in nodes if (n.get_name() or '').split('\n', 1)[0] == label])
    if command == 'fill-role' and len(found) != 1:
        raise RuntimeError('Expected one editable field with role ' + label)
    if not found:
        raise RuntimeError(f'Control not found: {label}')
    node = found[0]
    if command == 'inspect':
        result = []
        current = node
        for _ in range(6):
            action = current.get_action_iface()
            result.append({'name': current.get_name(), 'role': current.get_role_name(), 'actions': ([action.get_action_name(i) for i in range(action.get_n_actions())] if action else []), 'children': [{'name': current.get_child_at_index(i).get_name(), 'role': current.get_child_at_index(i).get_role_name()} for i in range(current.get_child_count())]})
            current = current.get_parent()
    elif command == 'actions':
        action = node.get_action_iface()
        result = [action.get_action_name(i) for i in range(action.get_n_actions())] if action else []
    elif command == 'tap':
        action = node.get_action_iface()
        index = next(i for i in range(action.get_n_actions()) if action.get_action_name(i) == 'Tap')
        result = action.do_action(index)
    elif command == 'click':
        result = False
        for _ in range(10):
            action = node.get_action_iface()
            if action:
                names = [action.get_action_name(i).lower() for i in range(action.get_n_actions())]
                preferred = ('tap', 'click', 'press', 'activate', 'focus')
                choices = [i for desired in preferred for i, name in enumerate(names) if name == desired]
                if choices:
                    result = action.do_action(choices[0])
                    break
            node = node.get_parent()
            if node is None:
                break
        if not result:
            raise RuntimeError('No activation action for ' + label)
    elif command in ('fill', 'fill-role'):
        result = node.get_editable_text_iface().set_text_contents(sys.argv[3])
    elif command == 'form-text':
        if label not in ('Media address', 'Display name (optional)') or len(found) != 1:
            raise RuntimeError('Expected one authored non-secret Open media field')
        if node.get_role_name() == 'password text':
            raise RuntimeError('Protected text readback is forbidden')
        text = node.get_text_iface()
        if text is None:
            raise RuntimeError('Open media field has no accessible text')
        result = text.get_text(0, text.get_character_count())
    elif command == 'length':
        result = node.get_text_iface().get_character_count()
    elif command == 'state':
        result = node.get_state_set().contains(Atspi.StateType.CHECKED)
    else:
        raise ValueError(command)
    print(json.dumps(result))


def serve():
    # Keep one accessibility-bus client alive across the complete UI scenario.
    # Repeated short-lived clients churn GTK's key-event listener registration.
    SOCKET.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(SOCKET))
        SOCKET.chmod(0o600)
        server.listen(1)
        while True:
            client, _ = server.accept()
            with client, client.makefile('rb') as stream:
                try:
                    sys.argv = ['qa-ui', *json.loads(stream.readline(65536))]
                    context = GLib.MainContext.default()
                    for _ in range(100):
                        if not context.pending():
                            break
                        context.iteration(False)
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        main()
                    result = {'result': json.loads(output.getvalue())}
                except Exception as error:
                    result = {'error': str(error)}
                client.sendall((json.dumps(result) + '\n').encode())


if __name__ == '__main__':
    if sys.argv[1] == 'serve':
        serve()
    else:
        main()
