function spt_savevideo_smoke()
% Verify the track player's Save video: it must NOT fail with "Frame must be W by H" — every frame is
% locked to the first frame's EVEN dimensions. Renders real movie frames through the actual player path.
here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fileparts(here));                                    % repo root: spt_test_data lives there
mov = spt_test_data(fullfile('WithER','spt','250408_WT_012_spt1.tif'));
if isempty(mov)
    fprintf('SKIP %s — test dataset not installed (see spt_test_data.m)\n', mfilename);
    return
end
assert(isfile(mov), 'test movie missing');

fp = uifigure('Visible','off','Position',[0 0 720 560]);
ctl = spt_track_movie(fp);
R = struct('sptPath',mov,'base','savevid_test', ...
    'trackId',ones(30,1), 'frame',(100:129)', ...           % 0-based frames -> span 101..130
    'x',10+0.12*(0:29)', 'y',12+0.08*(0:29)');
ctl.load(R, 1);

out = fullfile(tempdir, 'spt_savevid_test.mp4');
if isfile(out), delete(out); end
ctl.saveVideo(out);                                          % must not throw / must not fail on frame size
if ~isfile(out)                                             % MPEG-4 may fall back to .avi on some hosts
    [pd,b] = fileparts(out); avi = fullfile(pd,[b '.avi']); if isfile(avi), out = avi; end
end
assert(isfile(out), 'no video file written');

v = VideoReader(out);
fprintf('wrote %s: %d frames, %dx%d\n', out, v.NumFrames, v.Width, v.Height);
assert(v.NumFrames == 30, 'expected 30 frames, got %d', v.NumFrames);
assert(mod(v.Width,2)==0 && mod(v.Height,2)==0, 'video dims not even (%dx%d) — H.264 needs even', v.Width, v.Height);

ctl.stop(); delete(fp); delete(out);
fprintf('\nSAVE-VIDEO SMOKE PASSED.\n');
end
