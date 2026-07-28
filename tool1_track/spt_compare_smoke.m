function spt_compare_smoke()
% Verify the 3-way linking-method comparison: the engine (spt_method_compare) runs full tracking under
% all three modes + finds link disagreements, and the app (spt_compare_app) renders the bar chart +
% example difference panels. Runs on a SMALL frame window for speed.
here = fileparts(mfilename('fullpath')); addpath(here);
W = '/Users/safal-mac/Desktop/IntegratedPipeline/WithER';
cel = struct('key','250408_WT_012', 'spt',fullfile(W,'spt','250408_WT_012_spt1.tif'), ...
    'erSeg',fullfile(W,'er_seg','250408_VAPB_WT_012_2_TA_BC.tiff'), 'diamUm',0.5);
prm = struct('linkUm',0.8,'gapUm',1.4,'maxGap',1,'lambda',3,'pxUm',0.10785);
assert(isfile(cel.spt) && isfile(cel.erSeg), 'test data (WithER spt/er_seg) missing');

%% engine ---------------------------------------------------------------
cmp = spt_method_compare(cel, prm, 'Frames',[1 120], 'MaxInstances',9);
c = cmp.counts;
fprintf('tracks: euclid=%d penalty=%d geodesic=%d | disagreements=%d\n', ...
    c.euclid.nTracks, c.penalty.nTracks, c.geodesic.nTracks, cmp.summary.nDiff);
assert(all([c.euclid.nTracks c.penalty.nTracks c.geodesic.nTracks] > 0), 'a method produced 0 tracks');
assert(isfield(cmp,'tracks') && iscell(cmp.tracks.geodesic), 'per-mode tracks not returned');
assert(istable(cmp.instances), 'instances not a table');
assert(numel(cmp.dets)==120 && numel(cmp.ERs)==120, 'dets/ERs length wrong');
% the three methods should not all be identical on a real ER cell
assert(~(c.euclid.nTracks==c.penalty.nTracks && c.euclid.nTracks==c.geodesic.nTracks) || cmp.summary.nDiff>0, ...
    'methods identical AND no disagreements — engine likely not distinguishing modes');
% instances table has all three methods' partner columns
need = {'euX','peX','geX','euOff','peOff','geOff'};
assert(all(ismember(need, cmp.instances.Properties.VariableNames)), 'instances missing method columns');

%% app ------------------------------------------------------------------
f = spt_compare_app(cel, prm, struct('frames',[1 120],'maxImages',9));   % auto-runs on the small window
bars = findobj(f,'Type','bar'); assert(~isempty(bars) && numel(bars(1).YData)==3, 'bar chart missing/wrong');
assert(all(bars(1).YData>0), 'bar track counts not positive');
imgs = findobj(f,'Type','image'); assert(~isempty(imgs), 'no example difference images rendered');
ta = findobj(f,'Type','uitextarea'); joined = strjoin(string(ta(1).Value(:)'),' | ');
assert(contains(joined,'TRACKS') && contains(joined,'ER-geodesic'), 'summary missing method track counts');

% min-length filter must re-count from the stored tracks (no re-tracking) and never exceed the raw count
raw = bars(1).YData;
sp = findobj(f,'Type','uispinner'); emm = sp(arrayfun(@(s) isequal(s.Limits,[1 1e5]), sp));
assert(~isempty(emm), 'no min-length spinner');
emm(1).Value = 50; cb = emm(1).ValueChangedFcn; cb(emm(1), struct());
fil = findobj(f,'Type','bar'); fil = fil(1).YData;
assert(all(fil <= raw), 'filtered (>=50) counts exceed raw counts');
assert(all(fil >= 0), 'negative counts');
fprintf('app: %d bars · %d example images · minLen filter raw %s -> >=50 %s\n', ...
    numel(raw), numel(imgs), mat2str(raw), mat2str(fil));

% backdrop toggle must re-render the examples on the raw frame / ER mask (no re-tracking)
dd = findobj(f,'Type','uidropdown'); ddb = dd(arrayfun(@(d) iscell(d.Items) && any(strcmp(d.Items,'ER mask')), dd));
assert(~isempty(ddb), 'no backdrop dropdown');
for mode = {'raw','mask','rawer'}
    ddb(1).Value = mode{1}; cb = ddb(1).ValueChangedFcn; cb(ddb(1), struct());
    assert(~isempty(findobj(f,'Type','image')), 'backdrop %s produced no image', mode{1});
end
fprintf('backdrop toggle OK (raw frame · ER mask · raw+outline)\n');
delete(f);

fprintf('\nMETHOD-COMPARE (3-way) SMOKE PASSED.\n');
end
