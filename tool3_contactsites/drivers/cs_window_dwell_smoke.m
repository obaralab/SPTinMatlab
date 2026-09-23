function cs_window_dwell_smoke()
% Headless validation of cs_window_dwell: (A) runs on real mapped data, checks event accounting
% and per-window k_out; (B) a hand-built CSW with a known inside/outside sequence to verify the
% (span+1)*dt dwell accounting and window clipping against a closed-form expectation.
here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
addpath(fileparts(fileparts(here)));                 % repo root, for spt_test_data
% Part A needs a real built project. It is not in the repo, so on a fresh clone there is nothing to
% check against and erroring would only be noise -- say so and leave.
anaDir = spt_test_data(fullfile('Project','analysis'));
if isempty(anaDir)
    fprintf('SKIP %s — test dataset not installed (see spt_test_data.m)\n', mfilename);
    return
end

fprintf('\n========== PART A: real mapped data ==========\n');
assert(isfile(fullfile(anaDir,'CSW_final.mat')),'run cs_window_mapper first');
DD = cs_window_dwell(anaDir, struct('save',true,'verbose',true));
assert(~isempty(DD.events),'no dwell events');
% every event dwell must be a positive multiple of dt and >= dt (span+1>=1)
d = DD.allDwell;
assert(all(d>0),'non-positive dwell'); assert(min(d) >= DD.dt-1e-9,'dwell < dt');
% perSite kout consistency
for s = DD.perSite
    if s.numDwell>0, assert(abs(s.kout - s.numDwell/max(s.total_s,eps)) < 1e-6,'kout mismatch'); end
end
fprintf('events=%d  tracks-at-CS=%d  median dwell=%.4fs  pooled k_out=%.3f /s\n', ...
    numel(DD.events), numel(DD.perTrack), median(d), numel(d)/max(sum(d),eps));
labs = {DD.perTrack.label};
fprintf('labels: RESIDENT=%d ENTERS=%d EXITS=%d ENTERS+EXITS=%d\n', ...
    nnz(strcmp(labs,'RESIDENT')), nnz(strcmp(labs,'ENTERS')), nnz(strcmp(labs,'EXITS')), nnz(strcmp(labs,'ENTERS+EXITS')));

fprintf('\n========== PART B: closed-form dwell accounting ==========\n');
% One site, two windows. A single member track: inside for frames 2..5 (win1) and 12..14 (win2),
% outside elsewhere. Footprint = unit box at origin; member coord inside = (0,0), outside = (10,10).
dt = 0.5;
nF = 20; fr = (1:nF)';
xr = 10*ones(nF,1); yr = 10*ones(nF,1);           % outside (box is +-0.5 about 0)
xr([2 3 4 5 12 13 14]) = 0; yr([2 3 4 5 12 13 14]) = 0;   % inside episodes
refb = 0.5*[-1 -1;1 -1;1 1;-1 1;-1 -1];
CStemplate = struct('file','SYN','cellIndex',1,'csID',1,'window',1,'winFrames',[1 10], ...
    'siteUID',1,'center',[0 0],'refCenter',[0 0],'refboundary',refb,'footprintMode','box', ...
    'EllipseFit',[],'boundaries',struct('x',refb(:,1),'y',refb(:,2)),'tracks',1,'nTracks',1, ...
    'LocIDs',(1:nF)','nMemberLocs',nF,'CSmatrix',cat(3,fr,xr,yr),'MitoFlag',true, ...
    'SF',0.03,'grid',921,'binAreaUm2',0.03^2,'dt',dt,'areaUm2',1,'nLocInside',7, ...
    'cellTotalLocWin',nF,'probMass',0.35,'peakProb',0,'peakProbRaw',0,'localDens',0, ...
    'cellBgDens',0,'enrichment',0,'densSrc','tracked');
w1 = CStemplate; w1.window=1; w1.winFrames=[1 10]; w1.siteUID=1;
w2 = CStemplate; w2.window=2; w2.winFrames=[11 20]; w2.siteUID=2;
CSW = [w1 w2]; %#ok<NASGU>
tmp = fullfile(tempdir,'cswd_smoke'); if ~isfolder(tmp), mkdir(tmp); end
save(fullfile(tmp,'CSW_final.mat'),'CSW');
DD2 = cs_window_dwell(tmp, struct('save',false,'verbose',true));
% window 1 sees the 2..5 episode only (clipped to frames 1..10): dwell = (5-2+1)*dt = 4*0.5 = 2.0
% window 2 sees the 12..14 episode only (frames 11..20): dwell = (14-12+1)*dt = 3*0.5 = 1.5
e1 = DD2.events([DD2.events.window]==1); e2 = DD2.events([DD2.events.window]==2);
fprintf('win1 events=%d dwell=%s  win2 events=%d dwell=%s\n', numel(e1), mat2str([e1.dwell]), numel(e2), mat2str([e2.dwell]));
assert(numel(e1)==1 && abs(e1.dwell-2.0)<1e-9, 'win1 dwell != 2.0');
assert(numel(e2)==1 && abs(e2.dwell-1.5)<1e-9, 'win2 dwell != 1.5');
% k_out per window: 1 event / total dwell
k1 = DD2.perWindow([DD2.perWindow.window]==1).kout_w;
k2 = DD2.perWindow([DD2.perWindow.window]==2).kout_w;
assert(abs(k1-1/2.0)<1e-9 && abs(k2-1/1.5)<1e-9,'k_out(w) mismatch (%.4f %.4f)',k1,k2);
fprintf('k_out(w1)=%.4f (=1/2.0)  k_out(w2)=%.4f (=1/1.5)  -- window clipping + span+1 accounting correct\n', k1, k2);

fprintf('\n========== PART C: the >=%% inside filter (dwelling vs passing through) ==========\n');
% Same box, one window, TWO member tracks over 20 frames:
%   track 1 DWELLS  — inside for 16 of its 20 window frames (80%)
%   track 2 PASSES  — inside for 4 of its 20 window frames (20%), in one short visit
% At minPctInside = 50 only track 1 survives, so the events, the per-track rows and k_out must all
% be the dwelling track's alone. This is a selection on the measured quantity: mean dwell can only
% go up and k_out can only go down, which is exactly why the threshold travels with the result.
frC = (1:nF)';
x1 = 10*ones(nF,1); y1 = 10*ones(nF,1); x1(3:18) = 0; y1(3:18) = 0;   % 16/20 inside
x2 = 10*ones(nF,1); y2 = 10*ones(nF,1); x2(5:8)  = 0; y2(5:8)  = 0;   %  4/20 inside
wC = CStemplate;
wC.window = 1; wC.winFrames = [1 20]; wC.siteUID = 1;
wC.tracks = [1 2]; wC.nTracks = 2;
wC.CSmatrix = cat(3, [frC frC], [x1 x2], [y1 y2]);
CSW = wC;
save(fullfile(tmp,'CSW_final.mat'),'CSW');

D0  = cs_window_dwell(tmp, struct('save',false,'verbose',false));                       % every member
D50 = cs_window_dwell(tmp, struct('save',false,'verbose',false,'minPctInside',50));     % dwelling only
assert(numel(D0.perTrack)==2, 'unfiltered run kept %d member tracks, wanted 2', numel(D0.perTrack));
assert(isscalar(D50.perTrack), '>=50%% kept %d member tracks, wanted 1', numel(D50.perTrack));
assert(D50.perTrack(1).trackCol==1, '>=50%% kept the passing-through track, not the dwelling one');
pcts = sort([D0.perTrack.pctInside]);
assert(abs(pcts(1)-20)<1e-9 && abs(pcts(2)-80)<1e-9, 'pctInside is %s, wanted 20 and 80', mat2str(pcts));
assert(D50.minPctInside==50 && D0.minPctInside==0, 'the threshold did not travel with the result');
% the surviving numbers are the dwelling track's: one 16-frame episode = 16*dt = 8 s
assert(isscalar(D50.events) && abs(D50.events.dwell-16*dt)<1e-9, ...
    'filtered dwell = %s, wanted %g s', mat2str([D50.events.dwell]), 16*dt);
assert(numel(D0.events)==2, 'unfiltered run found %d events, wanted 2', numel(D0.events));
fprintf('pctInside = %s ; >=50%% keeps 1 of 2 tracks; dwell %g s -> %g s, k_out %.4f -> %.4f /s\n', ...
    mat2str(pcts), sum([D0.events.dwell]), sum([D50.events.dwell]), ...
    D0.perSite(1).kout, D50.perSite(1).kout);

% A site with no qualifying track at all must report NO escape rate, not one of zero: 0/s means
% "never leaves", and averaging that into a condition would drag its k_out towards zero.
D99 = cs_window_dwell(tmp, struct('save',false,'verbose',false,'minPctInside',99));
assert(isempty(D99.events), '>=99%% should have kept no track here');
assert(isnan(D99.perSite(1).kout) && isnan(D99.perSite(1).meanDwell), ...
    'a site with no qualifying track reported k_out=%g — no events is no rate, not a rate of zero', ...
    D99.perSite(1).kout);
fprintf('no qualifying track -> k_out is NaN (dropped downstream), not 0\n');

fprintf('\nALL DWELL SMOKE ASSERTIONS PASSED.\n');
end
