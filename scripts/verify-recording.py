import array
import json
import math
import subprocess
import sys
from pathlib import Path

folder = Path.home() / 'tmp/investigations/scarlett-mono'
recording = Path(sys.argv[1]) if len(sys.argv) > 1 else max(folder.glob('Screen Recording *.mov'), key=lambda p: p.stat().st_mtime)
probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(recording)], timeout=15))
audio = next(stream for stream in probe['streams'] if stream['codec_type'] == 'audio')
assert audio['channels'] == 2, f"Expected stereo file, got {audio['channels']} channels"
raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(recording), '-map', '0:a:0', '-t', '60', '-f', 'f32le', '-acodec', 'pcm_f32le', '-'], timeout=20)
samples = array.array('f', raw)
left = samples[0::2]
right = samples[1::2]
assert left and right, 'Recording has no audio samples'
peak_left = max(map(abs, left))
peak_right = max(map(abs, right))
difference = max(abs(a - b) for a, b in zip(left, right))
rms_left = math.sqrt(sum(value * value for value in left) / len(left))
rms_right = math.sqrt(sum(value * value for value in right) / len(right))
assert peak_left > 0.00001 and peak_right > 0.00001, 'Audio is silent'
assert difference < 0.00001, f'Audio channels differ: {difference}'
result = {'recording': str(recording), 'codec': audio['codec_name'], 'channels': audio['channels'], 'sampleRate': audio['sample_rate'], 'duration': probe['format']['duration'], 'framesChecked': len(left), 'leftPeak': peak_left, 'rightPeak': peak_right, 'leftRMS': rms_left, 'rightRMS': rms_right, 'maximumChannelDifference': difference, 'result': 'PASS'}
(folder / 'recording-verification.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
