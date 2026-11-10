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
    nodes = [node for app in apps if 'pleazyng' in (app.get_name() or '').lower() for node in walk(app)]
    command = sys.argv[1]
    if command == 'dump':
        print(json.dumps([{'name': n.get_name(), 'role': n.get_role_name()} for n in nodes]))
        return
    label = sys.argv[2]
    found = [n for n in nodes if (n.get_name() or '').split('\n', 1)[0] == label]
    if not found:
        raise RuntimeError(f'Control not found: {label}')
    node = found[0]
    if command == 'click':
        result = node.get_action_iface().do_action(0)
    elif command == 'fill':
        result = node.get_editable_text_iface().set_text_contents(sys.argv[3])
    elif command == 'focus':
        result = node.get_component_iface().grab_focus()
    elif command == 'state':
        result = node.get_state_set().contains(Atspi.StateType.CHECKED)
    elif command == 'rect':
        r = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
        result = {'x': r.x, 'y': r.y, 'width': r.width, 'height': r.height}
    else:
        raise ValueError(command)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
