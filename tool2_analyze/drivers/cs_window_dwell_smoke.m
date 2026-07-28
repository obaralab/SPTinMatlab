function cs_window_dwell_smoke()
% Headless validation of cs_window_dwell: (A) runs on real mapped data, checks event accounting
% and per-window k_out; (B) a hand-built CSW with a known inside/outside sequence to verify the
% (span+1)*dt dwell accounting and window clipping against a closed-form expectation.
here = fileparts(mfilename('fullpath')); addpath(here);
anaDir = '/Users/safal-mac/Desktop/IntegratedPipeline/Project/analysis';

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

fprintf('\nALL DWELL SMOKE ASSERTIONS PASSED.\n');
end
