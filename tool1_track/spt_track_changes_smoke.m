function spt_track_changes_smoke()
% Verify this increment: (1) player shows the TRUE movie length (5981) not the track span; (2) the
% Detect tab has the Top%/Quality-≥ mode with percentile default 6 and a working enable-toggle;
% (3) the provenance writers record mode + quality_min and upsert the project summary CSV.
here = fileparts(mfilename('fullpath')); addpath(here);
mov  = '/Users/safal-mac/Desktop/IntegratedPipeline/WithER/spt/250408_WT_012_spt1.tif';

%% (1) PLAYER: true movie length vs track span -------------------------------------------------
assert(isfile(mov), 'test movie missing'); ninfo = numel(imfinfo(mov));
fprintf('movie IFDs (imfinfo) = %d\n', ninfo);
assert(ninfo == 5981, 'expected 5981 frames, imfinfo says %d', ninfo);
fp = uifigure('Visible','off','Position',[0 0 900 600]);
ctl = spt_track_movie(fp);
R = struct('sptPath',mov,'base','250408_WT_012_spt1', ...
    'trackId',[1 1 1 2 2]', 'frame',[500 1000 5555 600 800]', ...   % 0-based; track span ends at 5555
    'x',[10 12 14 20 22]', 'y',[10 11 12 30 31]');
ctl.load(R, [1 2]);
axT = ctl.axes; ttl = axT.Title.String;
fprintf('player title: %s\n', ttl);
assert(contains(ttl,'of 5981 frames'), 'title does not show true movie length: %s', ttl);
assert(contains(ttl,'track span'),     'title does not label the span: %s', ttl);
sld = findobj(fp,'Type','uislider');
assert(~isempty(sld) && abs(sld(1).Limits(2)-5981)<0.5, 'slider does not span the whole movie: %s', mat2str(sld(1).Limits));
lbls = findobj(fp,'Type','uilabel'); ftxt = '';
for L = lbls(:)', if contains(L.Text,'frame ') && contains(L.Text,'/'), ftxt = L.Text; break; end, end
fprintf('frame label: %s\n', ftxt);
assert(contains(ftxt,'/5981'), 'frame label does not show /5981: "%s"', ftxt);
% ---- the player must not keep drawing into graphics that have gone -------------------------------
% It runs on a timer while the rest of the app is live, so a tick can land inside another callback
% that is rebuilding graphics. Observed in Tool 3: pressing Compute on the Compare tab calls
% legend(), and a tick fired during legend's removeAllEntries —
%   "Warning: Error in state of SceneNode. Invalid or deleted object."
% repeating for as long as the timer ran. draw() checked only hImg; it also writes to the frame
% label and the trail/head lines, so killing those (what a teardown does) left it spinning.
lastwarn('');
ctl.load(R, [1 2]);                                  % load auto-starts playback (button reads Pause)
nRunBefore = 0; tt = timerfindall;
for q = 1:numel(tt), if strcmp(tt(q).Running,'on'), nRunBefore = nRunBefore + 1; end, end
assert(nRunBefore >= 1, 'fixture check: the player should be ticking after load');
pause(0.25);
delete(findobj(fp,'Type','uilabel'));                % handles draw() wrote to UNGUARDED
delete(findobj(fp,'Type','line'));
pause(0.5);                                          % let several ticks fire at the wreckage
nRun = 0; tt = timerfindall;
for q = 1:numel(tt), if strcmp(tt(q).Running,'on'), nRun = nRun + 1; end, end
[wmsg,~] = lastwarn;
assert(nRun == 0, 'the player kept ticking against dead graphics (%d timer(s) running)', nRun);
assert(isempty(wmsg), 'a tick against dead graphics warned: %s', wmsg);
fprintf('  PLAYER TEARDOWN OK — a tick into deleted graphics stops the timer, silently.\n');

ctl.stop(); delete(fp);
fprintf('  PLAYER OK — true length 5981 shown, span labelled, slider spans movie.\n\n');

%% (2) DETECT TAB: mode toggle + percentile default 6 -----------------------------------------
f = spt_app();
dds = findobj(f,'Type','uidropdown'); ddMode = [];
for d = dds(:)', if iscell(d.Items) && any(strcmp(d.Items,'Quality ≥')), ddMode = d; break; end, end
assert(~isempty(ddMode), 'no Top%%/Quality threshold-mode dropdown found');
spins = findobj(f,'Type','uispinner');
spnP = spins(arrayfun(@(s) isequal(s.Limits,[0.1 100]), spins));   % Top % spinner
spnQ = spins(arrayfun(@(s) isequal(s.Limits,[0 1e6]),  spins));    % Quality ≥ spinner
assert(~isempty(spnP) && spnP(1).Value==6, 'Top%% default is not 6 (got %g)', spnP(1).Value);
assert(~isempty(spnQ), 'no Quality-≥ spinner found');
assert(strcmp(spnQ(1).Enable,'off'), 'Quality spinner should start disabled (pct mode)');
% flip to Quality ≥ via its callback -> the quality spinner must enable
ddMode.Value = 'qual'; cb = ddMode.ValueChangedFcn; cb(ddMode, struct('Value','qual'));
assert(strcmp(spnQ(1).Enable,'on'),  'Quality spinner did not enable in qual mode');
assert(strcmp(spnP(1).Enable,'off'), 'Top%% spinner did not disable in qual mode');
% min track length default is 50
mls = spins(arrayfun(@(s) isequal(s.Limits,[1 1e5]), spins));
assert(~isempty(mls) && mls(1).Value==50, 'min track length default is not 50 (got %g)', mls(1).Value);
fprintf('  DETECT OK — Top%% default 6, min-len 50, mode toggle enables/disables correctly.\n\n');
delete(f);

%% (3) PROVENANCE WRITERS: settings mode + quality_min, and CSV upsert -------------------------
td = fullfile(tempdir,'spt_prov_test'); if isfolder(td), rmdir(td,'s'); end, mkdir(td);
Rr = struct('spotId',(1:120)','nTracks',9,'erAware',1,'haveEr',1,'haveMito',1);
prm = struct('linkUm',0.8,'gapUm',1.4,'maxGap',1,'lambda',3,'pxUm',0.10785,'dtS',0.020064,'linkMode','geodesic');
% cell A: percentile mode + geodesic tracking
celA = struct('diamUm',0.5,'keepPct',6,'thrMode','pct','qualThr',[],'thrAbs',17.79);
spt_write_settings(td,'cellA',celA,prm,Rr); spt_append_detection_summary(td,'cellA',celA,prm,Rr);
sA = fileread(fullfile(td,'cellA_settings.txt'));
assert(contains(sA,'threshold_mode= top-percentile'),'A: mode not recorded');
assert(contains(sA,'detection.top_percent   = 6'),   'A: percentile 6 not recorded');
assert(contains(sA,'tracking.method         = ER-geodesic'),'A: tracking METHOD not recorded');
assert(contains(sA,'tracking.link_mode      = geodesic'),   'A: link_mode key not recorded');
% cell B: quality mode + Euclidean tracking
celB = struct('diamUm',0.5,'keepPct',6,'thrMode','qual','qualThr',22.5,'thrAbs',22.5);
prmE = prm; prmE.linkMode = 'euclid';
spt_write_settings(td,'cellB',celB,prmE,Rr); spt_append_detection_summary(td,'cellB',celB,prmE,Rr);
sB = fileread(fullfile(td,'cellB_settings.txt'));
assert(contains(sB,'threshold_mode= quality-abs'),'B: qual mode not recorded');
assert(contains(sB,'detection.quality_min   = 22.5'),'B: quality_min not recorded');
assert(contains(sB,'tracking.method         = Euclidean'),'B: Euclidean method not recorded');
% summary CSV has both cells, one row each, and records the linking method
csv = strsplit(strtrim(fileread(fullfile(td,'detection_summary.csv'))), newline);
assert(numel(csv)==3, 'summary should have header + 2 rows, got %d lines', numel(csv));
assert(contains(csv{1},'link_mode'),'summary header missing link_mode column');
assert(any(startsWith(csv,'cellA,top-percentile,6,')),   'cellA row missing/incorrect');
assert(any(contains(csv,',geodesic,')),'cellA link_mode geodesic missing from summary');
assert(any(contains(csv,',euclid,')),  'cellB link_mode euclid missing from summary');
% curation stamp: exporting _filtered appends the filter params to the SAME settings file (upsert).
% The two spot counts are deliberately DIFFERENT: every detection is written (the cloud is preserved,
% so n_spots_written equals the raw count), while only some belong to the tracks that survived. The
% old single key was named "n_spots_kept" and carried the WRITTEN count, so it read as though the
% filter had dropped 93% of tracks but kept every spot.
stat = struct('before',9,'after',5,'nSpots',120,'nSpotsKept',37);
spt_append_curation_settings(td,'cellA',50,0.2,stat);
sA2 = fileread(fullfile(td,'cellA_settings.txt'));
assert(contains(sA2,'curation.min_track_len  = 50'),'curation min_track_len not stamped');
assert(contains(sA2,'tracking.method         = ER-geodesic'),'curation stamp clobbered the tracking method');
assert(~contains(sA2,'n_spots_kept'), 'the misleading curation.n_spots_kept key is back');
assert(contains(sA2,'curation.n_spots_written= 120'), 'written-spot count not stamped');
assert(contains(sA2,'curation.n_spots_in_kept_tracks = 37'), 'kept-track spot count not stamped');
spt_append_curation_settings(td,'cellA',20,0.2,stat);   % re-curate -> upsert, not duplicate
sA3 = fileread(fullfile(td,'cellA_settings.txt'));
assert(numel(strfind(sA3,'curation.min_track_len'))==1,'curation block duplicated on re-export');
assert(contains(sA3,'curation.min_track_len  = 20'),'curation upsert did not update min_track_len');
% upsert of the summary row: re-run cellA with a different percentile -> still 2 rows, cellA updated
celA2 = celA; celA2.keepPct = 3;
spt_append_detection_summary(td,'cellA',celA2,prm,Rr);
csv2 = strsplit(strtrim(fileread(fullfile(td,'detection_summary.csv'))), newline);
assert(numel(csv2)==3, 'upsert changed row count (got %d)', numel(csv2));
assert(any(startsWith(csv2,'cellA,top-percentile,3,')), 'upsert did not update cellA to pct 3');
fprintf('  PROVENANCE OK — tracking method + params in settings + summary; curation stamp upserts.\n\n');
rmdir(td,'s');

fprintf('ALL TRACK-TOOL CHANGE ASSERTIONS PASSED.\n');
end
