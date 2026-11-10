#!/usr/bin/env python3
"""AT-SPI client for the installed release app; no application test build needed."""
import json
import sys
import gi

gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


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
    found = [n for n in nodes if (n.get_name() or '').split('\n', 1)[0] == label]
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
    elif command == 'fill':
        result = node.get_editable_text_iface().set_text_contents(sys.argv[3])
    elif command == 'length':
        result = node.get_text_iface().get_character_count()
    elif command == 'state':
        result = node.get_state_set().contains(Atspi.StateType.CHECKED)
    else:
        raise ValueError(command)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
