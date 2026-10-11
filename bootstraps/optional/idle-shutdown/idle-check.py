#!/usr/bin/env python3
"""idle-check.py — Timestamp parsing, idle detection, state management.

Used by idle-check.sh (systemd timer, every 5 min) to determine whether
the machine should shut down due to user inactivity.

Activity detection: count every role=user message UNLESS it starts with a
known automated prefix. This is a blocklist (not an allowlist) so TUI,
web, Slack, Discord, and any future surface all count automatically.

Customize via env:
  IDLE_EXTRA_AUTOMATED_PREFIXES  comma-separated list of additional prefixes
                                 to treat as automated (not human activity)
"""
import sys, json, os
from datetime import datetime, timezone


class ScanError(Exception):
    """Raised when session directory cannot be read."""
    pass


def parse_ts(ts):
    """Parse ISO 8601 timestamps — handles Z, +00:00, and fractional seconds."""
    if not ts or not isinstance(ts, str):
        return None
    # Normalize Z to +00:00 for fromisoformat compatibility
    normalized = ts.replace('Z', '+00:00') if ts.endswith('Z') else ts
    try:
        dt = datetime.fromisoformat(normalized)
        # Coerce naive datetimes to UTC — prevents TypeError on comparison/subtraction
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, AttributeError):
        pass
    # Fallback for edge-case formats
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try:
            return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


# Default prefixes that indicate automated/system messages (not real human input).
# Add more via env IDLE_EXTRA_AUTOMATED_PREFIXES="Prefix A,Prefix B".
_DEFAULT_AUTOMATED_PREFIXES = (
    'Read HEARTBEAT.md',
    'System:',
    'Pre-compaction memory flush',
    '[Heartbeat]',
    '[System]',
)


def _automated_prefixes():
    """Combine default + env-configured prefixes. Called per-scan (cheap)."""
    extra = os.environ.get('IDLE_EXTRA_AUTOMATED_PREFIXES', '')
    extras = tuple(p.strip() for p in extra.split(',') if p.strip())
    return _DEFAULT_AUTOMATED_PREFIXES + extras


def _is_real_user_message(text):
    """Return True for genuine human activity, False for automated messages.

    Blocklist approach: a message counts as real human activity unless it
    starts with a known automated prefix. This ensures TUI/web/Slack/Discord
    messages — which don't carry Telegram sender_id metadata — still count.

    Inbound messages from chat surfaces often lead with a metadata header
    (e.g. 'Conversation info (untrusted metadata)' JSON block) before the
    actual user text. We strip leading whitespace and the common metadata
    wrapper before matching, so those still count as real activity.
    """
    if not text:
        return False

    # Peel off any leading 'Conversation info ...' / 'Sender ...' metadata blocks
    # before checking for automated prefixes, so real user text underneath them
    # is evaluated rather than the wrapper.
    stripped = text.lstrip()
    for wrapper in ('Conversation info', 'Sender (untrusted'):
        if stripped.startswith(wrapper):
            # Find the user's actual text after the closing fence, if any.
            idx = stripped.find('```\n', stripped.find('```') + 1)
            if idx != -1:
                after = stripped[idx + 4:].lstrip()
                if after:
                    stripped = after
                    break

    for prefix in _automated_prefixes():
        if stripped.startswith(prefix):
            return False
    return True


def _extract_text(obj):
    """Extract ALL text content from a session JSONL message object.

    Concatenates all content parts instead of only inspecting the first one.
    """
    msg = obj.get('message', {})
    content = msg.get('content', []) if isinstance(msg, dict) else []
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                t = item.get('text', '')
                if t:
                    parts.append(t)
            elif isinstance(item, str):
                parts.append(item)
        return '\n'.join(parts)
    return ''


def find_idle_hours(sessions_dir):
    """Find hours since last real user activity.

    Returns (hours_idle, latest_ts_str, file_failures, parse_failures) or
    (None, None, file_failures, parse_failures) if no messages found.
    Raises ScanError if the sessions directory cannot be read.
    Compares parsed datetime objects, not strings (fixes mixed-format sorting).
    """
    try:
        entries = os.listdir(sessions_dir)
    except OSError as e:
        raise ScanError(f"Cannot read sessions directory {sessions_dir}: {e}")

    latest_dt = None
    latest_ts = None
    parse_failures = 0
    file_read_failures = 0

    for fname in entries:
        if not fname.endswith('.jsonl') or '.checkpoint.' in fname:
            continue
        path = os.path.join(sessions_dir, fname)
        try:
            with open(path, encoding='utf-8', errors='replace') as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                        # Skip a valid JSON line that is not an object ([], "x", 1, null).
                        # Without this, obj.get raises AttributeError and the scan fails.
                        if not isinstance(obj, dict):
                            continue
                        msg = obj.get('message', {})
                        role = msg.get('role') if isinstance(msg, dict) else obj.get('role')
                        if role != 'user':
                            continue
                        text = _extract_text(obj)
                        if not _is_real_user_message(text):
                            continue
                        ts = obj.get('createdAt') or obj.get('timestamp') or obj.get('ts')
                        if not ts:
                            continue
                        dt = parse_ts(ts)
                        if dt is None:
                            parse_failures += 1
                            continue
                        if latest_dt is None or dt > latest_dt:
                            latest_dt = dt
                            latest_ts = ts
                    except (json.JSONDecodeError, KeyError):
                        pass
        except OSError as e:
            file_read_failures += 1
            print(f"WARNING: Could not read {path}: {e}", file=sys.stderr)

    if file_read_failures > 0 and latest_dt is None:
        # Files failed to read AND no activity found — not safe to report NO_MESSAGES
        raise ScanError(
            f"{file_read_failures} session file(s) unreadable and no activity found — "
            f"refusing to report NO_MESSAGES"
        )

    if parse_failures > 0:
        print(f"WARNING: {parse_failures} timestamp(s) could not be parsed", file=sys.stderr)

    if latest_dt is None:
        return None, None, file_read_failures, parse_failures
    hours = (datetime.now(timezone.utc) - latest_dt).total_seconds() / 3600
    return hours, latest_ts, file_read_failures, parse_failures


# --- Legacy functions (kept for backward compat) ---

def latest_user_ts(sessions_dir):
    _, ts, _, _ = find_idle_hours(sessions_dir)
    return ts


def hours_idle(ts_str):
    dt = parse_ts(ts_str)
    if dt is None:
        return None
    return (datetime.now(timezone.utc) - dt).total_seconds() / 3600


def get_state(state_file, key):
    """Read a key from the JSON state file."""
    try:
        with open(state_file) as f:
            return json.load(f).get(key, False)
    except (OSError, json.JSONDecodeError):
        return False


def set_state(state_file, key, value):
    """Write a key to the JSON state file (atomic-ish via tmp + rename)."""
    try:
        with open(state_file) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        data = {}
    data[key] = value
    os.makedirs(os.path.dirname(state_file), exist_ok=True)
    tmp = state_file + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, state_file)


def get_uptime_hours():
    """Get system uptime in hours from /proc/uptime."""
    try:
        with open('/proc/uptime') as f:
            return float(f.read().split()[0]) / 3600
    except (OSError, ValueError):
        return 999  # assume long uptime if unreadable


# --- CLI interface ---
if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: idle-check.py <command> [args...]", file=sys.stderr)
        print("Commands: --idle-hours, --latest-ts, --hours-idle, --should-shutdown,", file=sys.stderr)
        print("          --float-gt, --float-lt, --uptime-hours, --get-state, --set-state", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == '--idle-hours':
        # Combined: find latest + compute idle hours in one call (preferred)
        try:
            hours, ts, file_fails, parse_fails = find_idle_hours(sys.argv[2])
        except ScanError as e:
            print(f'SCAN_ERROR {e}')
            sys.exit(0)  # exit clean so bash can handle the status
        except Exception as e:
            # Catch-all: any unexpected error = SCAN_ERROR (fail closed)
            print(f'SCAN_ERROR unexpected: {e}')
            sys.exit(0)
        if hours is None:
            print('NO_MESSAGES')
        else:
            print(f'{hours:.4f} {ts} {file_fails} {parse_fails}')

    elif cmd == '--latest-ts':
        try:
            ts = latest_user_ts(sys.argv[2])
        except ScanError:
            print('')
        else:
            print(ts or '')

    elif cmd == '--hours-idle':
        h = hours_idle(sys.argv[2])
        if h is None:
            print('PARSE_ERROR')
            sys.exit(1)
        print(f'{h:.4f}')

    elif cmd == '--should-shutdown':
        print('yes' if float(sys.argv[2]) > float(sys.argv[3]) else 'no')

    elif cmd == '--float-gt':
        # Replace bc: print 'yes' if arg1 > arg2
        print('yes' if float(sys.argv[2]) > float(sys.argv[3]) else 'no')

    elif cmd == '--float-lt':
        # Replace bc: print 'yes' if arg1 < arg2
        print('yes' if float(sys.argv[2]) < float(sys.argv[3]) else 'no')

    elif cmd == '--uptime-hours':
        print(f'{get_uptime_hours():.4f}')

    elif cmd == '--get-state':
        print(str(get_state(sys.argv[2], sys.argv[3])).lower())

    elif cmd == '--set-state':
        val = sys.argv[4]
        parsed = True if val == 'true' else False if val == 'false' else val
        set_state(sys.argv[2], sys.argv[3], parsed)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
