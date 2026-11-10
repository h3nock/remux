#!/usr/bin/env python3
"""Records demo takes of Remux on a simulator and renders them for the site.

  site_demo.py setup           create and boot the demo simulator, build Remux, install it there
  site_demo.py play FLOW.json  play a timeline on the app as it is set up there, recording the screen
  site_demo.py record          record while you use the app in the Simulator by hand; Return stops
  site_demo.py render TAKE     cut and encode a take's video, and size its screenshots, for the page

Set the app up on the demo simulator first (servers, sessions, whatever the flow shows): play and record use it as
it is, and draw each touch on the screen. Run setup again after the app's code changes. Each take is a folder in
.local/site-demo/takes/ holding screen.mp4, touches.jsonl (each touch's start and end), steps.jsonl (when each step
began, for play), shots/ (the timeline's screenshots) and take.json.

A timeline is {"pause": 1.0, "steps": [...]}: the steps play in order, with `pause` seconds after each gesture and
each typing step (default 1). Steps:

  {"tap": TARGET}
  {"press": TARGET, "for": 1.0}          a long-press, held this many seconds
  {"drag": TARGET, "to": [x, y], "hold": 0.6, "speed": 200, "end": 0.3}
      touch down, hold, move to `to` at `speed` points a second, hold at the end, lift. `to` is in the same
      element (or the screen) as the start. The terminal's arrow keys are a drag with a hold.
  {"swipe": "up", "on": TARGET, "length": 0.4, "speed": 450, "count": 1, "gap": 0.12}
      a flick over `length` of the element (or of the screen, without "on"), the finger moving up, down, left or
      right. With "count", that many flicks in a row, each `gap` seconds after the last lifted, as a person scrolls
      a long way
  {"type": "git status\\n"}               types into whatever has the keyboard, 10 characters a
                                         second ("speed"); \\n is Return. With "clear": true, first
                                         deletes what the field holds
  {"wait": 2}                            seconds
  {"waitFor": TARGET, "timeout": 30}     until it is on screen
  {"shot": "agents"}                     saves the screen as shots/agents.png
  {"mark": "start"}                      render cuts from mark "start" to mark "end"

TARGET is an element's accessibility identifier or label, such as "terminal.screen" or "Agents" (a row's label
starts with its name, so "web" is the row "web, tmux, ..."), with "at": [x, y] for a point in it (fractions of its width and height from the top left; the middle by default), or a point on the
screen, [x, y]. A gesture waits up to 15 s for its element; if it never shows, the error lists what is on screen.

  {"steps": [
    {"tap": "my-server"},
    {"mark": "start"},
    {"swipe": "up", "on": "terminal.screen"},
    {"drag": "terminal.screen", "at": [0.3, 0.45], "to": [0.75, 0.45]},
    {"shot": "arrows"},
    {"mark": "end"}
  ]}

Needs Xcode, ffmpeg (with libx264 and libwebp) and Python 3.9+.
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORK = REPO / '.local' / 'site-demo'
BUILD = WORK / 'build'
TAKES = WORK / 'takes'
APP = BUILD / 'Build' / 'Products' / 'Debug-iphonesimulator' / 'Remux.app'
BUNDLE_ID = 'dev.remux.app'
SCHEME = 'RemuxUIOnly'
PLAYER = 'RemuxUITests/DemoTimelineUITests/testPlayDemoTimeline'
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
# Screens the site shows: each in three widths, for 2x and 3x displays and the full-size viewer.
SHOT_SIZES = ((600, '', 90), (900, '-900', 90), (None, '-{width}', 85))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sim', default='remux-demo', help='the demo simulator, by name (default: remux-demo)')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('setup', help='create and boot the demo simulator, build Remux, install it there')
    play_parser = commands.add_parser('play', help='play a timeline, recording the screen')
    play_parser.add_argument('flow', type=Path, help='the timeline, a JSON file')
    commands.add_parser('record', help='record while you use the app by hand')
    render_parser = commands.add_parser('render', help="cut and encode a take's video and size its screenshots")
    render_parser.add_argument('take', type=Path, help="the take's folder")
    render_parser.add_argument('--from', dest='start', help='where the cut starts: seconds into the recording, or a '
                               'mark (default: mark "start", else half a second before the first touch)')
    render_parser.add_argument('--to', dest='end', help='where it ends: seconds or a mark (default: mark "end", else '
                               'a second and a half after the last touch)')
    render_parser.add_argument('--speed', type=float, default=1.0, help='playback speed (default 1)')
    render_parser.add_argument('--fast', nargs=3, action='append', default=[], metavar=('FROM', 'TO', 'TIMES'),
                               help='play part of the cut TIMES faster, such as a page loading: FROM and TO are '
                               'seconds into the recording or marks (repeatable)')
    render_parser.add_argument('--width', type=int, default=900, help='video width in pixels (default 900: a 300 px '
                               'phone on a 3x display)')
    render_parser.add_argument('--poster', type=float, default=0.0, help='the poster frame, in seconds into the cut '
                               '(default 0, the first frame, so playing it starts without a jump)')
    render_parser.add_argument('--name', help="the video's file name (default: the take's)")
    render_parser.add_argument('--out', type=Path, help="where the files go (default: the take's site/ folder)")
    args = parser.parse_args()
    {'setup': setup, 'play': play, 'record': record, 'render': render}[args.command](args)


# Simulator


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, capture_output=True, **kwargs).stdout


def simulator(name, create=False):
    """The simulator's UDID, booted. With create, makes it first if it doesn't exist."""
    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
    found = [d for runtime in devices.values() for d in runtime if d['name'] == name and d.get('isAvailable', True)]
    if len(found) > 1:
        sys.exit(f'more than one simulator is named {name}; pass --sim with a unique name')
    if found:
        udid = found[0]['udid']
    elif create:
        runtimes = json.loads(run(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
        ios = [r for r in runtimes if r.get('platform') == 'iOS' and r.get('isAvailable')]
        if not ios:
            sys.exit('no iOS simulator runtime is installed')
        newest = max(ios, key=lambda r: [int(part) for part in r['version'].split('.')])
        udid = run(['xcrun', 'simctl', 'create', name, DEVICE_TYPE, newest['identifier']]).strip()
        print(f'created simulator {name} ({newest["name"]})')
    else:
        sys.exit(f'no simulator named {name}: run setup first')
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
    return udid


def tidy_status_bar(udid):
    """The status bar every Apple screenshot has. Booting resets it, so each take sets it again."""
    run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '9:41', '--dataNetwork', 'wifi',
         '--wifiMode', 'active', '--wifiBars', '3', '--cellularMode', 'active', '--cellularBars', '4',
         '--batteryState', 'discharging', '--batteryLevel', '100'])


def require_app(udid):
    if subprocess.run(['xcrun', 'simctl', 'get_app_container', udid, BUNDLE_ID], capture_output=True).returncode:
        sys.exit('Remux is not installed on the demo simulator: run setup first')


def setup(args):
    udid = simulator(args.sim, create=True)
    run(['xcrun', 'simctl', 'ui', udid, 'appearance', 'dark'])
    tidy_status_bar(udid)
    WORK.mkdir(parents=True, exist_ok=True)
    print('building Remux and its timeline player (log: .local/site-demo/build.log) ...')
    with open(WORK / 'build.log', 'w') as log:
        built = subprocess.run(['xcodebuild', 'build-for-testing', '-project', str(REPO / 'Remux.xcodeproj'),
                                '-scheme', SCHEME, '-destination', f'platform=iOS Simulator,id={udid}',
                                '-derivedDataPath', str(BUILD)], cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
    if built.returncode:
        errors = sorted({line.strip() for line in open(WORK / 'build.log') if ' error: ' in line})
        sys.exit('build failed:\n' + '\n'.join(errors[:20]))
    run(['xcrun', 'simctl', 'install', udid, str(APP)])
    print(f'Remux is installed on {args.sim}. To set it up by hand, open it in the Simulator:\n'
          f'  open -a Simulator --args -CurrentDeviceUDID {udid}')


# Takes


class Recording:
    """The simulator's screen, recorded to a file. `started` is the wall-clock time the recorder says it started,
    which is the video's time zero, so render can place the touch and step logs in the video."""

    def __init__(self, udid, path):
        self.process = subprocess.Popen(['xcrun', 'simctl', 'io', udid, 'recordVideo', '--codec=h264', '--force',
                                         str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.output = []
        for line in self.process.stdout:
            self.output.append(line)
            if 'Recording started' in line:
                self.started = time.time()
                return
        sys.exit('the screen recording did not start:\n' + ''.join(self.output))

    def stop(self):
        self.process.send_signal(signal.SIGINT)
        try:
            self.process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            self.process.kill()
            sys.exit('the screen recording did not finish writing')


def new_take(name):
    take = TAKES / f'{name}-{datetime.now():%Y%m%d-%H%M%S}'
    take.mkdir(parents=True)
    return take


def write_take(take, udid, name, recording, **extra):
    info = {'name': name, 'simulator': udid, 'video_started': recording.started, **extra}
    (take / 'take.json').write_text(json.dumps(info, indent=2) + '\n')


def play(args):
    flow = args.flow.resolve()
    try:
        json.loads(flow.read_text())
    except (OSError, ValueError) as error:
        sys.exit(f'{flow}: {error}')
    if not list((BUILD / 'Build' / 'Products').glob(f'{SCHEME}_*.xctestrun')):
        sys.exit('the timeline player is not built: run setup first')
    udid = simulator(args.sim)
    require_app(udid)
    tidy_status_bar(udid)
    take = new_take(flow.stem)
    shutil.copy(flow, take / 'flow.json')
    recording = Recording(udid, take / 'screen.mp4')
    print(f'playing {flow.name} into {take.relative_to(REPO)} ...')
    try:
        with open(take / 'test.log', 'w') as log:
            # No diagnostics after a failure: collecting them can hold xcodebuild for ten minutes.
            result = subprocess.run(
                ['xcodebuild', 'test-without-building', '-project', str(REPO / 'Remux.xcodeproj'), '-scheme', SCHEME,
                 '-destination', f'platform=iOS Simulator,id={udid}', '-derivedDataPath', str(BUILD),
                 f'-only-testing:{PLAYER}', '-collect-test-diagnostics', 'never',
                 '-resultBundlePath', str(take / 'result.xcresult')],
                cwd=REPO, stdout=log, stderr=subprocess.STDOUT,
                env={**os.environ, 'TEST_RUNNER_REMUX_DEMO_TIMELINE': str(take / 'flow.json'),
                     'TEST_RUNNER_REMUX_DEMO_TAKE': str(take)})
    finally:
        recording.stop()
    write_take(take, udid, flow.stem, recording, flow=str(flow))
    if result.returncode:
        errors = [line.strip() for line in open(take / 'test.log') if ' error: ' in line]
        sys.exit('the timeline stopped:\n' + ('\n'.join(errors[:5]) or 'see test.log') +
                 f'\nthe recording so far is in {take.relative_to(REPO)}')
    shutil.rmtree(take / 'result.xcresult', ignore_errors=True)
    print(f'done: {take.relative_to(REPO)}\nnext: scripts/site_demo.py render {take.relative_to(REPO)}')


def record(args):
    udid = simulator(args.sim)
    require_app(udid)
    tidy_status_bar(udid)
    take = new_take('manual')
    env = {**os.environ, 'SIMCTL_CHILD_REMUX_DEBUG_SHOW_TOUCHES': '1',
           'SIMCTL_CHILD_REMUX_DEBUG_TOUCH_LOG': str(take / 'touches.jsonl')}
    run(['xcrun', 'simctl', 'launch', '--terminate-running-process', udid, BUNDLE_ID], env=env)
    recording = Recording(udid, take / 'screen.mp4')
    try:
        input('Recording, with your touches drawn. Use the app in the Simulator, then press Return to stop. ')
    except (KeyboardInterrupt, EOFError):
        print()
    finally:
        recording.stop()
    write_take(take, udid, 'manual', recording)
    print(f'done: {take.relative_to(REPO)}\nnext: scripts/site_demo.py render {take.relative_to(REPO)}')



# Rendering


def lines(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def ffmpeg(*arguments, **kwargs):
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', *arguments], check=True, **kwargs)


# The recorder gives runs of frames the same or out-of-order timestamps, and ffmpeg's timestamp-based steps (its fps
# filter, seeking) then place frames up to seconds from where they belong. The timestamps themselves are right: a
# clock the app drew into every frame matched them to within 32 ms (7 Nov). So each frame is decoded once, in order,
# and placed by its own timestamp here.
EVERY_FRAME = 'settb=1/1000,setpts=N'


def frame_stamps(video):
    """Each frame's timestamp, in seconds from the start of the recording, in the order the frames decode."""
    return sorted(float(value.strip(',')) for value in run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=pts_time', '-of', 'csv=p=0',
         str(video)]).split() if value.strip(','))


def render(args):
    take = args.take.resolve()
    info = json.loads((take / 'take.json').read_text())
    video = take / 'screen.mp4'
    started = info['video_started']
    times = [started + stamp for stamp in frame_stamps(video)]
    marks = {step['mark']: step['t'] for step in lines(take / 'steps.jsonl') if 'mark' in step}
    touches = [touch['t'] for touch in lines(take / 'touches.jsonl') if 't' in touch]

    def when(value, default):
        """A cut point in wall-clock seconds, from a mark or from seconds into the recording."""
        if value is None:
            return default
        if value in marks:
            return marks[value]
        try:
            return started + float(value)
        except ValueError:
            sys.exit(f'no mark "{value}" in this take (marks: {", ".join(marks) or "none"})')

    start = max(times[0], when(args.start, marks.get('start', touches[0] - 0.5 if touches else times[0])))
    end = min(times[-1], when(args.end, marks.get('end', touches[-1] + 1.5 if touches else times[-1])))
    if end <= start:
        sys.exit(f'the cut is empty: from {start - started:.2f}s to {end - started:.2f}s')
    out = (args.out or take / 'site').resolve()
    out.mkdir(parents=True, exist_ok=True)
    name = args.name or info['name']

    # The cut at a steady 60 frames a second: each output frame shows the last recorded frame by its time.
    source_width, source_height = (int(value) for value in run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height', '-of',
         'csv=p=0:s=x', str(video)]).strip().split('x'))
    height = round(source_height * args.width / source_width / 2) * 2
    size = args.width * height * 3 // 2
    fast = []
    for first, last, factor in args.fast:
        try:
            fast.append((when(first, None), when(last, None), float(factor)))
        except ValueError:
            sys.exit(f'--fast {first} {last} {factor}: TIMES is a number')
    # The moment of the recording each output frame shows: a steady step, shorter where the cut plays faster.
    dues, due = [], start
    while due < end:
        dues.append(due)
        due += args.speed * next((factor for first, last, factor in fast if first <= due < last), 1) / 60
    slots = len(dues)
    poster_slot = min(slots - 1, int(args.poster * 60))
    raw = ['-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-s', f'{args.width}x{height}', '-color_range', 'tv',
           '-colorspace', 'bt709']
    # Raw output still warns about the shared timestamps; the frame count is checked instead.
    decoder = subprocess.Popen(['ffmpeg', '-loglevel', 'fatal', '-i', str(video), '-vf',
                                f'{EVERY_FRAME},scale={args.width}:{height}:flags=lanczos', '-fps_mode', 'passthrough',
                                '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-'], stdout=subprocess.PIPE)
    encoder = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', *raw, '-r', '60', '-i', '-',
                                # The recorder tags its video Display P3, but the pixels are the screen's sRGB values
                                # (a frame matches the screenshot of the same moment; converting from P3 darkened
                                # it), so the frames are tagged sRGB.
                                '-vf', 'setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709',
                                '-an', '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-pix_fmt', 'yuv420p',
                                '-movflags', '+faststart', str(out / f'{name}.mp4')], stdin=subprocess.PIPE)
    frame, index = None, -1
    for slot, due in enumerate(dues):
        while index + 1 < len(times) and (frame is None or times[index + 1] <= due):
            index += 1
            frame = decoder.stdout.read(size)
            if len(frame) < size:
                decoder.kill()
                encoder.kill()
                sys.exit(f'decoding the recording stopped at frame {index} of {len(times)}')
        encoder.stdin.write(frame)
        if slot == poster_slot:
            ffmpeg(*raw, '-i', '-', '-frames:v', '1', '-c:v', 'libwebp', '-quality', '85', '-compression_level', '6',
                   str(out / f'{name}-poster.webp'), input=frame)
    # The frames after the cut aren't needed.
    decoder.kill()
    decoder.wait()
    encoder.stdin.close()
    if encoder.wait():
        sys.exit('encoding the video failed')
    print(f'{name}.mp4: {start - started:.2f}s to {end - started:.2f}s of the recording, {slots / 60:.1f}s at '
          f'{args.speed:g}x, {args.width}x{height}, {(out / f"{name}.mp4").stat().st_size // 1024} KB; '
          f'poster {name}-poster.webp')

    for shot in sorted((take / 'shots').glob('*.png')):
        shot_width = int(run(['ffprobe', '-v', 'error', '-show_entries', 'stream=width', '-of', 'csv=p=0',
                              str(shot)]))
        made = []
        for width, suffix, quality in SHOT_SIZES:
            target = out / f'{shot.stem}{suffix.format(width=shot_width)}.webp'
            ffmpeg('-i', str(shot), '-vf', f'scale={width or shot_width}:-2:flags=lanczos', '-c:v', 'libwebp',
                   '-quality', str(quality), '-compression_level', '6', str(target))
            made.append(f'{target.name} {target.stat().st_size // 1024} KB')
        print(f'{shot.name}: ' + ', '.join(made))
    print(f'in {out}')




if __name__ == '__main__':
    main()
