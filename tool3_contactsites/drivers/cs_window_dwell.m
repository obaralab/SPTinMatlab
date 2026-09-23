function DD = cs_window_dwell(anaDir, opts)
%CS_WINDOW_DWELL  Per-window residence-time analysis of mapped contact sites (headless).
%
%   DD = cs_window_dwell(anaDir)
%   DD = cs_window_dwell(anaDir, opts)
%
% Reads analysis/CSW_final.mat (from cs_window_mapper) and, for each (site x window) and each of
% its member tracks, computes dwell EVENTS clipped to that site's OWN window frame range. A dwell
% event is a maximal run of CONSECUTIVE in-footprint localizations; duration = (exitF-entryF+1)*dt.
% Because a footprint is only valid in the window it was detected for, clipping to winFrames makes
% residence genuinely time-resolved and yields a per-window escape rate k_out(w) = nEvents/sum(dwell).
%
% Reuses cs_dwell_primitives (csInsideMask/runsToEvents/mergeIntervals/classifyInside) verbatim.
%
% TWO DEFINITIONS OF A VISIT, one result. opts.method:
%   'inside' (default) a visit is a run of consecutive localizations INSIDE the outline. Crisp, and
%            it ends at the first localization outside - a molecule that steps out for one frame
%            starts a new visit.
%   'trace'  the visit is read off the distance-to-centre trace instead (cs_engage_detect): a
%            Schmitt trigger with two radii and a tolerance for brief excursions - what the VAPB
%            work marked by hand on that same plot. On its annotated data this reproduces 83% of
%            the hand-picked events at 87% precision, with dwell times agreeing to a median ratio
%            of 0.96 (cs_engage_smoke). Thresholds scale with each site's own radius.
% Everything downstream (the table, k_out, the labels) is the same either way, so the two are
% directly comparable - and DD.method records which one produced the numbers.
%
% opts: .save (true) writes analysis/cs_window_dwell.csv + cs_window_track_labels.csv; .verbose (true);
%       .minPctInside (0) keeps only member tracks with at least this % of their window
%       localizations INSIDE the footprint — the mapper's own trackPctInside criterion, the same one
%       the Sites tab's "≥% in" filter uses. 0 keeps every member.
%
% WHAT THE THRESHOLD DOES TO THE ANSWER. It separates tracks that DWELL from tracks that merely
% cross the site, and it is a selection on the very quantity being measured: raising it can only
% raise mean dwell and lower k_out, because the short visits are what it removes. That is the point
% when the question is "how long do the dwelling molecules stay", and it is a bias when the question
% is "how long does a molecule that arrives stay". Report the threshold with the number.
%
% OUTPUT struct DD:
%   .dt            representative frame interval (s)
%   .minPctInside  the threshold this result was computed at (0 = every member track)
%   .events        table-like struct array (one per dwell event)
%   .perSite       per (site x window): numDwell,longest_s,total_s,meanDwell,medianDwell,kout
%   .perWindow     per window index: nEvents, kout_w, medianDwell, dwell (pooled values)
%   .perTrack      per (site,track): label, numDwell, longest_s, total_s
%   .perTrackWin   per (cell,window,track): merged total residence (dedup overlapping sites)
%   .allDwell      pooled event dwell durations (s)

if nargin<2 || ~isstruct(opts), opts = struct(); end
doSave = getf(opts,'save',true);
verb   = getf(opts,'verbose',true);
minPct = getf(opts,'minPctInside',0);
method = lower(getf(opts,'method','inside'));            % 'inside' | 'trace'
engOpts = getf(opts,'engage',struct());                  % passed to cs_engage_detect for 'trace'
assert(isscalar(minPct) && isfinite(minPct) && minPct>=0 && minPct<=100, ...
    'cs_window_dwell:minPct','minPctInside must be a percentage in [0 100], got %s', mat2str(minPct));

here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
P = cs_dwell_primitives();

f = fullfile(anaDir,'CSW_final.mat');
assert(isfile(f),'cs_window_dwell:noCSW','Run the mapper first — missing %s', f);
Sc = load(f); CSW = Sc.CSW;
assert(~isempty(CSW),'cs_window_dwell:empty','CSW_final.mat has no sites');

dtv = [CSW.dt]; dt = median(dtv(dtv>0)); if ~(dt>0), dt = 0.02; end

ev = struct('file',{},'cellIndex',{},'csID',{},'window',{},'siteUID',{}, ...
            'mito',{},'trackCol',{},'entryFrame',{},'exitFrame',{},'dwell',{});
perTrack = struct('file',{},'cellIndex',{},'csID',{},'window',{},'siteUID',{},'trackCol',{}, ...
                  'label',{},'numDwell',{},'longest_s',{},'total_s',{},'pctInside',{});
nSeen = 0; nKept = 0;    % member tracks considered vs kept, for the threshold report

for k = 1:numel(CSW)
    e = CSW(k);
    if isempty(e.CSmatrix) || isempty(e.tracks), continue; end
    f0 = e.winFrames(1); f1 = e.winFrames(2);
    bx = e.refboundary(:,1); by = e.refboundary(:,2);        % um, rel refCentre
    for jj = 1:numel(e.tracks)
        fr = e.CSmatrix(:,jj,1); xr = e.CSmatrix(:,jj,2); yr = e.CSmatrix(:,jj,3);
        if isinf(f0)&&isinf(f1), wm = isfinite(fr);
        else, wm = fr>=f0 & fr<=f1 & isfinite(fr); end
        if ~any(wm), continue; end
        inside = P.inside(xr,yr,bx,by) & wm;
        % The mapper's trackPctInside, recomputed from THIS run's footprint rather than read off the
        % record: locs inside and in-window over the track's finite positions in the window. Reading
        % the stored field would go stale the moment a footprint is refined after the mapper ran.
        nWin = nnz(wm & isfinite(xr) & isfinite(yr));
        pctIn = 100 * nnz(inside) / max(nWin,1);
        nSeen = nSeen + 1;
        if pctIn < minPct, continue; end                     % passing-through, not dwelling
        nKept = nKept + 1;
        if strcmp(method, 'trace')
            % the same visit, read off the distance trace: r(t) from the site centre, thresholds
            % scaled by the site's own equivalent radius
            Rsite = sqrt(max(polyarea(bx, by), eps)/pi);
            o = engOpts; o.dt = dt; o.siteRadius = Rsite;
            E = cs_engage_detect(hypot(xr(wm), yr(wm)), fr(wm), o);
            rev = zeros(numel(E), 3);
            for r = 1:numel(E), rev(r,:) = [E(r).entryFrame E(r).exitFrame E(r).dwell_s]; end
        else
            rev = P.runs(inside, fr, dt);                    % [entryF exitF dwell]
        end
        if isempty(rev), continue; end
        tcol = e.tracks(jj);
        for r = 1:size(rev,1)
            ev(end+1) = struct('file',e.file,'cellIndex',e.cellIndex,'csID',e.csID, ...
                'window',e.window,'siteUID',e.siteUID,'mito',cs_site_near(e,'mito'), ...
                'trackCol',tcol,'entryFrame',rev(r,1),'exitFrame',rev(r,2),'dwell',rev(r,3)); %#ok<AGROW>
        end
        % per (site,track) classification label (paper semantics: one track vs one CS)
        [cls,~,~] = P.classify(inside(wm), fr(wm));
        dv = rev(:,3);
        perTrack(end+1) = struct('file',e.file,'cellIndex',e.cellIndex,'csID',e.csID,'window',e.window, ...
            'siteUID',e.siteUID,'trackCol',tcol,'label',cls,'numDwell',size(rev,1), ...
            'longest_s',max(dv),'total_s',sum(dv),'pctInside',pctIn); %#ok<AGROW>
    end
end

allDwell = [ev.dwell]';
DD = struct();
DD.dt = dt; DD.method = method; DD.events = ev; DD.perTrack = perTrack; DD.allDwell = allDwell;
DD.minPctInside = minPct;      % travels with the result: a consumer must be able to say what it is looking at

% ---- per (site x window) aggregation ----
uids = unique([CSW.siteUID]);
perSite = struct('siteUID',{},'file',{},'cellIndex',{},'csID',{},'window',{},'mito',{}, ...
                 'numDwell',{},'longest_s',{},'total_s',{},'meanDwell',{},'medianDwell',{},'kout',{});
for u = uids
    E = ev([ev.siteUID]==u);
    base = CSW([CSW.siteUID]==u);
    d = [E.dwell]';
    perSite(end+1) = struct('siteUID',u,'file',base.file,'cellIndex',base.cellIndex, ...
        'csID',base.csID,'window',base.window,'mito',cs_site_near(base,'mito'), ...
        'numDwell',numel(d),'longest_s',safemax(d),'total_s',sum(d), ...
        'meanDwell',safemean(d),'medianDwell',safemed(d), ...
        'kout',safekout(d)); %#ok<AGROW>
end
DD.perSite = perSite;

% ---- per-window pooled (the time-resolved headline: k_out(w)) ----
wins = unique([CSW.window]);
perWindow = struct('window',{},'nEvents',{},'kout_w',{},'medianDwell',{},'meanDwell',{},'dwell',{});
for w = wins
    E = ev([ev.window]==w); d = [E.dwell]';
    perWindow(end+1) = struct('window',w,'nEvents',numel(d), ...
        'kout_w',safekout(d),'medianDwell',safemed(d), ...
        'meanDwell',safemean(d),'dwell',d); %#ok<AGROW>
end
DD.perWindow = perWindow;

% ---- per (cell,window,track) merged residence (dedup overlapping footprints in a window) ----
perTrackWin = struct('file',{},'cellIndex',{},'window',{},'trackCol',{}, ...
                     'numEpisodes',{},'total_s',{},'longest_s',{});
if ~isempty(ev)
    key = arrayfun(@(x) sprintf('%d|%d|%d', x.cellIndex, x.window, x.trackCol), ev, 'uni',0);
    uk = unique(key);
    for i = 1:numel(uk)
        E = ev(strcmp(key,uk{i}));
        iv = [[E.entryFrame]' [E.exitFrame]'];
        mg = P.merge(iv);
        spans = (mg(:,2)-mg(:,1)+1)*dt;
        perTrackWin(end+1) = struct('file',E(1).file,'cellIndex',E(1).cellIndex, ...
            'window',E(1).window,'trackCol',E(1).trackCol, ...
            'numEpisodes',size(mg,1),'total_s',sum(spans),'longest_s',max(spans)); %#ok<AGROW>
    end
end
DD.perTrackWin = perTrackWin;

if verb
    if minPct > 0
        fprintf('cs_window_dwell: >=%g%% inside kept %d of %d member tracks\n', minPct, nKept, nSeen);
    end
    fprintf('cs_window_dwell: %d events across %d site-windows, %d member-tracks; k_out/window:', ...
        numel(ev), numel(uids), numel(perTrack));
    for w = wins, fprintf(' w%d=%.2f', w, perWindow([perWindow.window]==w).kout_w); end
    fprintf('\n');
end

if doSave
    writeEventsCSV(fullfile(anaDir,'cs_window_dwell.csv'), ev);
    writeLabelsCSV(fullfile(anaDir,'cs_window_track_labels.csv'), perTrack);
    save(fullfile(anaDir,'cs_window_dwell.mat'),'DD','-v7.3');
    if verb, fprintf('  wrote cs_window_dwell.csv + cs_window_track_labels.csv + cs_window_dwell.mat\n'); end
end
end

% ================================================================================================
function writeEventsCSV(path, ev)
fid=fopen(path,'w'); if fid<0, return; end
fprintf(fid,'file,cellIndex,csID,window,siteUID,mito,trackCol,entryFrame,exitFrame,dwell_s\n');
for k=1:numel(ev), e=ev(k);
    fprintf(fid,'%s,%d,%d,%d,%d,%d,%d,%g,%g,%.6g\n', e.file,e.cellIndex,e.csID,e.window, ...
        e.siteUID,e.mito,e.trackCol,e.entryFrame,e.exitFrame,e.dwell);
end
fclose(fid);
end
function writeLabelsCSV(path, pt)
fid=fopen(path,'w'); if fid<0, return; end
fprintf(fid,'file,cellIndex,csID,window,siteUID,trackCol,label,numDwell,longest_s,total_s,pct_inside\n');
for k=1:numel(pt), e=pt(k);
    fprintf(fid,'%s,%d,%d,%d,%d,%d,%s,%d,%.6g,%.6g,%.4g\n', e.file,e.cellIndex,e.csID,e.window,e.siteUID, ...
        e.trackCol,e.label,e.numDwell,e.longest_s,e.total_s,e.pctInside);
end
fclose(fid);
end
function v=safekout(d)
% No events is NO escape rate, not an escape rate of ZERO. 0/s reads as "this molecule never
% leaves" — the exact opposite of "nothing was measured here" — and the old 0/eps produced it for
% any site with no events. A >=% inside filter routinely leaves a site with no qualifying track at
% all, so those sites would otherwise pull a condition's mean k_out towards zero.
if isempty(d), v = NaN; else, v = numel(d)/max(sum(d),eps); end
end
function v=safemax(d), if isempty(d), v=NaN; else, v=max(d); end, end
function v=safemean(d), if isempty(d), v=NaN; else, v=mean(d); end, end
function v=safemed(d), if isempty(d), v=NaN; else, v=median(d); end, end
function v=getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
