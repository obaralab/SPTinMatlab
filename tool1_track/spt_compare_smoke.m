function spt_compare_smoke()
% Verify the 3-way linking-method comparison: the engine (spt_method_compare) runs full tracking under
% all three modes + finds link disagreements, and the app (spt_compare_app) renders the bar chart and
% the three SIDE-BY-SIDE PLAYERS (one per method) with working playback and video export.
% Runs on a SMALL frame window for speed. Writes only to tempdir — never into the project or WithER.
here = fileparts(mfilename('fullpath')); addpath(here);
W = '/Users/safal-mac/Desktop/IntegratedPipeline/WithER';
cel = struct('key','250408_WT_012', 'spt',fullfile(W,'spt','250408_WT_012_spt1.tif'), ...
    'erSeg',fullfile(W,'er_seg','250408_VAPB_WT_012_2_TA_BC.tiff'), 'diamUm',0.5);
prm = struct('linkUm',0.8,'gapUm',1.4,'maxGap',1,'lambda',3,'pxUm',0.10785);
assert(isfile(cel.spt) && isfile(cel.erSeg), 'test data (WithER spt/er_seg) missing');

%% engine ---------------------------------------------------------------
cmp = spt_method_compare(cel, prm, 'Frames',[1 120]);
c = cmp.counts;
fprintf('tracks: euclid=%d penalty=%d geodesic=%d | disagreements=%d\n', ...
    c.euclid.nTracks, c.penalty.nTracks, c.geodesic.nTracks, cmp.summary.nDiff);
assert(all([c.euclid.nTracks c.penalty.nTracks c.geodesic.nTracks] > 0), 'a method produced 0 tracks');
assert(isfield(cmp,'tracks') && iscell(cmp.tracks.geodesic), 'per-mode tracks not returned');
assert(istable(cmp.instances), 'instances not a table');
assert(numel(cmp.dets)==120 && numel(cmp.ERs)==120, 'dets/ERs length wrong');
assert(~(c.euclid.nTracks==c.penalty.nTracks && c.euclid.nTracks==c.geodesic.nTracks) || cmp.summary.nDiff>0, ...
    'methods identical AND no disagreements — engine likely not distinguishing modes');
need = {'euX','peX','geX','euOff','peOff','geOff'};
assert(all(ismember(need, cmp.instances.Properties.VariableNames)), 'instances missing method columns');

% cmp.tracks column 1 is a WINDOW index (1..nF), NOT an absolute frame — the app converts with
% t = cmp.fr(1) + k - 1 and every overlay depends on it. Pin the convention here.
allk = cell2mat(cellfun(@(t) t(:,1), cmp.tracks.euclid(:), 'uni', 0));
assert(min(allk) >= 1 && max(allk) <= numel(cmp.dets), 'tracks col1 is not a window index');
assert(max(cmp.instances.frame) <= cmp.fr(2) && min(cmp.instances.frame) >= cmp.fr(1), ...
    'instances.frame is not an absolute movie frame');

%% app ------------------------------------------------------------------
f = spt_compare_app(cel, prm, struct('frames',[1 120],'maxImages',40));   % auto-runs on the small window
U = f.UserData;
bars = findobj(f,'Type','bar'); assert(~isempty(bars) && numel(bars(1).YData)==3, 'bar chart missing/wrong');
assert(all(bars(1).YData>0), 'bar track counts not positive');
imgs = findobj(f,'Type','image'); assert(numel(imgs) >= 6, 'expected 3 player images + 3 strips');
ta = findobj(f,'Type','uitextarea'); joined = strjoin(string(ta(1).Value(:)'),' | ');
assert(contains(joined,'TRACKS') && contains(joined,'ER-geodesic'), 'summary missing method track counts');

% the example list must be populated and ranked
tb = findobj(f,'Type','uitable'); assert(~isempty(tb), 'no example table');
assert(size(tb(1).Data,1) > 0, 'example table empty');
sc = cell2mat(tb(1).Data(:,5));
assert(all(diff(sc) <= 0), 'examples not sorted by descending difference score');
fprintf('examples: %d listed · top score %d · "%s"\n', size(tb(1).Data,1), sc(1), tb(1).Data{1,3});

% an example must be loaded, with a real frame window and a crop box
st = U.state(); assert(~isempty(st.ex), 'no example loaded on run');
assert(numel(st.ex.kw) >= 5, 'playback window too short to be a video');
bx = st.ex.box; assert(bx(2)>bx(1) && bx(4)>bx(3), 'degenerate crop box');
fprintf('example: %d frames · crop %dx%d px\n', numel(st.ex.kw), bx(2)-bx(1)+1, bx(4)-bx(3)+1);

% the three panels must be independent: at least one example where geodesic differs from Euclidean
nDiffPanels = 0;
for z = 1:min(10, numel(st.rank))
    U.pick(z); s2 = U.state();
    if ~isequal(s2.ex.V{3}, s2.ex.V{1}), nDiffPanels = nDiffPanels + 1; end
end
assert(nDiffPanels > 0, 'no example where the geodesic panel differs from Euclidean — panels not per-method');
fprintf('per-method panels differ in %d of the top 10 examples\n', nDiffPanels);

% seeking moves the current frame and redraws
U.pick(1); s0 = U.state(); U.seek(numel(s0.ex.kw)); s1 = U.state();
assert(s1.kcur ~= s0.kcur || numel(s0.ex.kw)==1, 'seek did not change the frame');
U.play(); assert(U.state().playing, 'play did not start'); U.play();
assert(~U.state().playing, 'pause did not stop');

% min-length filter must re-count from the stored tracks (no re-tracking) and never exceed the raw count
raw = bars(1).YData;
sp = findobj(f,'Type','uispinner'); emm = sp(arrayfun(@(s) isequal(s.Limits,[1 1e5]), sp));
assert(~isempty(emm), 'no min-length spinner');
emm(1).Value = 50; cb = emm(1).ValueChangedFcn; cb(emm(1), struct());
fil = findobj(f,'Type','bar'); fil = fil(1).YData;
assert(all(fil <= raw) && all(fil >= 0), 'min-length re-count wrong');
fprintf('app: %d bars · minLen filter raw %s -> >=50 %s\n', numel(raw), mat2str(raw), mat2str(fil));

% backdrop toggle must re-render the players (no re-tracking)
dd = findobj(f,'Type','uidropdown'); ddb = dd(arrayfun(@(d) iscell(d.Items) && any(strcmp(d.Items,'ER mask')), dd));
assert(~isempty(ddb), 'no backdrop dropdown');
for mode = {'raw','mask','rawer','ertint'}
    ddb(1).Value = mode{1}; cb = ddb(1).ValueChangedFcn; cb(ddb(1), struct());
    im = findobj(f,'Type','image'); assert(~isempty(im) && ~isempty(im(1).CData), 'backdrop %s produced no image', mode{1});
end
ddb(1).Value = 'rawer'; cb = ddb(1).ValueChangedFcn; cb(ddb(1), struct());
fprintf('backdrop toggle OK (raw · ER mask · raw+outline · raw+ER tint)\n');

% video export: writes a real, readable movie of the whole window
vpath = fullfile(tempdir, sprintf('spt_compare_smoke_%d.mp4', feature('getpid')));
if isfile(vpath), delete(vpath); end
U.saveVideo(vpath);
st = U.state();
assert(isfile(vpath), 'Save video produced no file');
vr = VideoReader(vpath); nv = vr.NumFrames; d = dir(vpath);
assert(nv == numel(st.ex.kw), 'video has %d frames, expected %d', nv, numel(st.ex.kw));
assert(vr.Width > 600, 'video is %d px wide — the three panels did not export', vr.Width);
fprintf('video: %d frames · %dx%d · %.0f kB\n', nv, vr.Width, vr.Height, d.bytes/1024);
clear vr; delete(vpath);

close(f);   % via CloseRequestFcn, so the playback timer is stopped and deleted
fprintf('\nMETHOD-COMPARE (3-way side-by-side video) SMOKE PASSED.\n');
end
