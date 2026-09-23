function G = cs_engage_classify(src, opts)
%CS_ENGAGE_CLASSIFY  Engaged or not, per member track of each contact site - the trackBinding the
%VAPB work assigned by eye, from the distance trace instead.
%
%   G = cs_engage_classify(anaDir)          % reads analysis/CSW_final.mat
%   G = cs_engage_classify(CSW, opts)       % or a mapped site array directly
%
% For every (site x window) and EVERY one of its member tracks - including the ones that never come
% close, because they are the denominator - this reads r(t), the distance from the site centre, finds
% the visits with cs_engage_detect, and decides whether that track ENGAGED the site.
%
% THE DECISION IS TWO THRESHOLDS, and they were chosen against his annotation, not by taste:
%   a track is ENGAGED if it has at least one visit lasting >= minEngage_s.
% On the 1,312 member tracks his annotator labelled (160 sites of CS_final_v3), that rule agrees with
% the human on 81% of tracks (sens 0.81, spec 0.80 at 0.30 s), and on the tracks both call engaged it
% recovers the number of engagements exactly 78% of the time and within one 97% (his mean 1.34 per
% engaged track, this 1.39). A four-feature discriminant fitted to the same labels does no better
% (0.808 cross-validated vs 0.805), which is why there is no trained model here: the rule is as good,
% it carries no dataset's fingerprint, and you can say what it does in one sentence.
%
% WHAT THE REMAINING DISAGREEMENT IS. It is mostly the definition, not the detection: the tracks this
% calls engaged and he did not have a median longest visit of 0.52 s - real visits he chose not to
% count - and 42% of the ones he called engaged and this misses have no approach in the trace at all.
% Agreement with a hand annotation is bounded by the annotator's own consistency; treat 0.30 s as
% "what he meant by bound", and set it yourself when you mean something else. minEngage_s = 0 counts
% every visit the detector finds.
%
% WHICH TRACKS ARE THE DENOMINATOR. This decides what "fraction engaged" means, and it is the easiest
% thing to get wrong. The mapper calls a track a MEMBER of a site when it has at least one
% localization INSIDE the outline - so membership already implies it touched the site, and on the
% CysLig data 90% of member tracks come out engaged, which says more about the selection than about
% the biology. His annotated sites hold the wider set (41% engaged), so to ask his question -
% "of the molecules that came NEAR this site, how many engaged it?" - the tracks that visited the
% neighbourhood box without ever entering the outline have to be in the denominator too. They are not
% stored by the mapper (only their count is), so opts.denominator = 'box' rebuilds them from the
% build. On CysLig that widens the denominator from 1,762 to 4,016 tracks.
%
% opts
%   .denominator  'members' (default) every track the mapper called a member of the site - already
%                 selected for touching it | 'box' those PLUS every track that entered the site's
%                 neighbourhood box in the window without entering the outline. 'box' needs the
%                 build: opts.tracks, or a project folder to read the active one from.
%   .tracks       the TrackStruct array, when 'box' is used and it is already in memory
%   .minEngage_s  (0.30) a visit this long makes the track engaged. IN SECONDS, so the same meaning
%                 holds at 11 ms and 26.7 ms frames.
%   .maxDepth     (Inf) also require a visit to REACH the site (min r <= maxDepth x site radius).
%                 Off by default: duration alone matched him best (see the smoke's scan).
%   .countGated   (true) .nEngage counts only visits that pass those gates; false counts every
%                 detected visit.
%   .detect       options for cs_engage_detect (radii, gap tolerance, .method 'steps')
%   .includeExcluded (false) keep sites whose cell the experiment manifest excludes. They carry
%                 .excluded from cs_condition_apply; by default they are skipped, because a cell
%                 excluded in the Experiment tab should not quietly reappear in a pooled number.
%   .minPctInside (0) drop member tracks below this % of window localizations inside the outline,
%                 matching cs_window_dwell's own threshold. 0 keeps every member track.
%   .save         (false) write cs_engage_tracks.csv + cs_engage_sites.csv next to the build
%   .anaDir       where to write them when CSW was passed in rather than a folder
%   .verbose      (true)
%
% OUTPUT G
%   .perTrack  one row per track in the denominator, engaged or not, .member saying which set it came
%              from: .engaged .nEngage .longest_s .total_s
%              .fracNear (fraction of its localizations within 2R) .minRrel (closest approach, in
%              site radii) .mobRatio (its mean square step during the longest visit over the rest of
%              the track - evidence it was held, reported but NOT part of the decision: it separates
%              his labels at AUC 0.62, against 0.89 for proximity) .censored .nLocWin
%   .perSite   per (site x window): .nTracks .nEngaged .fracEngaged .engagePerTrack
%              .engagePerEngaged .medianDwell_s .totalDwell_s .kout (engagements per second engaged)
%   .dwell     every engagement as a row - .dwell_s with its site, track, condition, .censored and
%              .trackObs_s (how long its track was observable at all, which is the CEILING on the
%              dwell it could have shown) - what a dwell-time histogram is built from
%              (cs_dwell_histogram)
%   .params    the thresholds these numbers were produced at. They travel with the result.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'));

minEng  = getf(opts,'minEngage_s',0.30);
maxDep  = getf(opts,'maxDepth',Inf);
gated   = getf(opts,'countGated',true);
dOpt    = getf(opts,'detect',struct());
minPct  = getf(opts,'minPctInside',0);
den     = lower(getf(opts,'denominator','members'));
inclEx  = getf(opts,'includeExcluded',false);
verb    = getf(opts,'verbose',true);
doSave  = getf(opts,'save',false);

anaDir = '';
if ischar(src) || isstring(src)
    anaDir = char(src);
    f = fullfile(anaDir,'CSW_final.mat');
    assert(isfile(f),'cs_engage_classify:noCSW','Run the mapper first — missing %s', f);
    CSW = load(f).CSW;
else
    CSW = src;
end
anaDir = getf(opts,'anaDir',anaDir);     % a caller that already loaded CSW can still ask for the CSVs
assert(~isempty(CSW),'cs_engage_classify:empty','no mapped sites to classify');

TS = getf(opts,'tracks',[]);
if strcmp(den,'box') && isempty(TS)
    assert(~isempty(anaDir),'cs_engage_classify:noBuild', ...
        'denominator ''box'' needs the tracks: pass opts.tracks, or a project folder to read the active build from');
    bp = cs_active_trackstruct(anaDir);
    assert(~isempty(bp) && isfile(bp),'cs_engage_classify:noBuild', ...
        'denominator ''box'' needs the build, and none is active in %s', anaDir);
    TS = load(bp).Tracks;
    if verb, fprintf('  denominator ''box'': read %s\n', bp); end
end

P = cs_dwell_primitives();
dtv = [CSW.dt]; dt = median(dtv(dtv>0)); if ~(dt>0), dt = 0.02; end

perTrack = emptyTrack(); perSite = emptySite(); dwell = emptyDwell();
nSkipEx = 0;
for k = 1:numel(CSW)
    e = CSW(k);
    if isempty(e.CSmatrix) || isempty(e.tracks), continue; end
    if ~inclEx && islogical(fieldOr(e,'excluded',false)) && fieldOr(e,'excluded',false)
        nSkipEx = nSkipEx + 1; continue;    % the manifest excludes this cell (cs_condition_apply)
    end
    bx = e.refboundary(:,1); by = e.refboundary(:,2);
    R  = sqrt(max(polyarea(bx,by),eps)/pi);                  % the site's own scale
    cond = fieldOr(e,'condition','');
    dte = fieldOr(e,'dt',dt); if ~(dte>0), dte = dt; end
    nT = 0; nE = 0; nEv = 0; dSite = [];
    % The traces to read: the members (already centred in CSmatrix), and for 'box' the tracks that
    % entered the neighbourhood box without entering the outline, centred here the same way.
    [trCols, trMat, isMem] = tracesFor(e, den, TS);
    for jj = 1:size(trMat, 2)
        fr = trMat(:,jj,1); xr = trMat(:,jj,2); yr = trMat(:,jj,3);
        wm = inWindow(fr, e.winFrames) & isfinite(xr) & isfinite(yr);
        if nnz(wm) < 2, continue; end
        if minPct > 0
            pctIn = 100 * nnz(P.inside(xr,yr,bx,by) & wm) / max(nnz(wm),1);
            if pctIn < minPct, continue; end
        else
            pctIn = 100 * nnz(P.inside(xr,yr,bx,by) & wm) / max(nnz(wm),1);
        end
        r = hypot(xr(wm), yr(wm)); fw = fr(wm);
        obs = (max(fw) - min(fw) + 1) * dte;      % how long this track was observable in the window:
                                                  % no visit of it can be longer, censored or not
        o = dOpt; o.dt = dte; if ~isfield(o,'siteRadius'), o.siteRadius = R; end
        E = cs_engage_detect(r, fw, o);
        keep = true(numel(E),1);
        for m = 1:numel(E)
            keep(m) = E(m).dwell_s >= minEng && (~isfinite(maxDep) || E(m).rMin <= maxDep*R);
        end
        Ek = E(keep);
        isEng = ~isempty(Ek);
        if gated, Ecount = Ek; else, Ecount = E; end
        % the mobility evidence, from the longest visit: was it slower while it was there?
        mob = NaN; longest = 0; cens = false;
        if ~isempty(Ecount)
            [longest, mi] = max([Ecount.dwell_s]);
            cens = any(~[Ecount.entryObserved]) || any(~[Ecount.exitObserved]);
            mob = mobRatio(xr(wm), yr(wm), Ecount(mi).entryIdx, Ecount(mi).exitIdx);
        end
        nT = nT + 1; nE = nE + isEng; nEv = nEv + numel(Ecount);
        for m = 1:numel(Ecount)
            dwell(end+1) = struct('file',e.file,'cellIndex',e.cellIndex,'csID',e.csID, ...
                'window',e.window,'siteUID',e.siteUID,'mito',cs_site_near(e,'mito'), ...
                'condition',cond,'trackCol',trCols(jj),'dwell_s',Ecount(m).dwell_s, ...
                'entryFrame',Ecount(m).entryFrame,'exitFrame',Ecount(m).exitFrame, ...
                'rMin',Ecount(m).rMin,'siteRadiusUm',R,'trackObs_s',obs, ...
                'censored',~(Ecount(m).entryObserved && Ecount(m).exitObserved)); %#ok<AGROW>
            dSite(end+1) = Ecount(m).dwell_s; %#ok<AGROW>
        end
        perTrack(end+1) = struct('file',e.file,'cellIndex',e.cellIndex,'csID',e.csID, ...
            'window',e.window,'siteUID',e.siteUID,'condition',cond,'trackCol',trCols(jj), ...
            'member',isMem(jj), ...
            'engaged',isEng,'nEngage',numel(Ecount),'longest_s',longest, ...
            'total_s',sum([Ecount.dwell_s]), 'fracNear',mean(r < 2*R),'minRrel',min(r)/R, ...
            'mobRatio',mob,'censored',cens,'nLocWin',nnz(wm),'obs_s',obs,'pctInside',pctIn, ...
            'siteRadiusUm',R); %#ok<AGROW>
    end
    if nT == 0, continue; end
    perSite(end+1) = struct('siteUID',e.siteUID,'file',e.file,'cellIndex',e.cellIndex, ...
        'csID',e.csID,'window',e.window,'mito',cs_site_near(e,'mito'),'condition',cond, ...
        'nTracks',nT,'nMembers',nnz(isMem),'nEngaged',nE,'fracEngaged',nE/nT,'nEngagements',nEv, ...
        'engagePerTrack',nEv/nT,'engagePerEngaged',nEv/max(nE,1), ...
        'medianDwell_s',med0(dSite),'totalDwell_s',sum(dSite), ...
        'kout',nEv/max(sum(dSite),eps),'siteRadiusUm',R); %#ok<AGROW>
end

G = struct('perTrack',perTrack,'perSite',perSite,'dwell',dwell,'dt',dt, ...
    'params',struct('minEngage_s',minEng,'maxDepth',maxDep,'countGated',gated, ...
                    'minPctInside',minPct,'denominator',den,'includeExcluded',inclEx,'detect',dOpt));
if verb
    engM = logical([perTrack.engaged]); nEngV = [perTrack.nEngage];
    fprintf('engagement [%s]: %d tracks over %d site-windows, %d engaged (%.0f%%), %d engagements (%.2f per engaged track)\n', den, ...
        numel(perTrack), numel(perSite), nnz(engM), 100*mean0(engM), ...
        numel(dwell), mean0(nEngV(engM)));
    if nSkipEx > 0
        fprintf('  skipped %d site-window(s) in cells the manifest excludes (includeExcluded = true keeps them)\n', nSkipEx);
    end
    if ~isempty(dwell)
        fprintf('  dwell: median %.3f s, mean %.3f s, %.0f%% censored (a lower bound)\n', ...
            med0([dwell.dwell_s]), mean0([dwell.dwell_s]), 100*mean0([dwell.censored]));
    end
end
if doSave && ~isempty(anaDir)
    writeCSV(fullfile(anaDir,'cs_engage_tracks.csv'), perTrack);
    writeCSV(fullfile(anaDir,'cs_engage_sites.csv'), perSite);
    save(fullfile(anaDir,'cs_engage.mat'),'G','-v7.3');
    if verb, fprintf('  wrote cs_engage_tracks.csv + cs_engage_sites.csv + cs_engage.mat\n'); end
end
end

% =================================================================================================
function [cols, M, isMem] = tracesFor(e, den, TS)
% The traces to classify at this site, centred on its refined centre. Members come straight from
% CSmatrix. 'box' adds the tracks that were in the neighbourhood box during the window but never
% inside the outline - the mapper keeps only their COUNT (nTracksNear), so they are rebuilt here.
cols = e.tracks(:)'; M = e.CSmatrix; isMem = true(1, numel(cols));
if ~strcmp(den,'box') || isempty(TS), return; end
i = findCell(TS, e.file); if i == 0, return; end
c = fieldOr(e,'refCenter', fieldOr(e,'refCentre',[]));
box = fieldOr(e,'boxUm',[]);
if numel(c) < 2 || isempty(box), return; end
A = TS(i).matrix(:,:,2); B = TS(i).matrix(:,:,3); Fr = TS(i).matrix(:,:,1);
ok = isfinite(A) & isfinite(B);
win = inWindow2(Fr, e.winFrames) & ok;
h = box/2;
inBox  = abs(A - c(1)) <= h & abs(B - c(2)) <= h & win;
inPoly = false(size(A));
Ar = A - c(1); Br = B - c(2);
inPoly(ok) = inpolygon(Ar(ok), Br(ok), e.refboundary(:,1), e.refboundary(:,2));
extra = setdiff(find(any(inBox & ~inPoly, 1)), cols);     % in the box, never inside the outline
if isempty(extra), return; end
n0 = size(M,1); n1 = size(A,1); n = max(n0, n1);
if n > n0, M = cat(1, M, nan(n-n0, size(M,2), 3)); end    % the build can be longer than CSmatrix
Me = nan(n, numel(extra), 3);
Me(1:n1, :, 1) = Fr(:, extra);
Me(1:n1, :, 2) = Ar(:, extra);
Me(1:n1, :, 3) = Br(:, extra);
M = cat(2, M, Me);
cols = [cols extra(:)'];
isMem = [isMem false(1, numel(extra))];
end

function i = findCell(TS, file)
i = 0;
f = char(file);
for q = 1:numel(TS)
    if strcmp(char(TS(q).file), f), i = q; return; end
end
[~, b] = fileparts(f);                                    % fall back on the base name
for q = 1:numel(TS)
    [~, bq] = fileparts(char(TS(q).file));
    if strcmp(bq, b), i = q; return; end
end
end

function m = inWindow2(Fr, wf)
if numel(wf) < 2 || (isinf(wf(1)) && isinf(wf(2))), m = isfinite(Fr); return; end
m = Fr >= wf(1) & Fr <= wf(2) & isfinite(Fr);
end

function q = mobRatio(x, y, i0, i1)
% Mean square step INSIDE the visit over the same outside it. A molecule that is held moves less;
% this is the second, independent channel - and it is weak on his data (AUC 0.62) because a member
% track's "outside" is itself near the site. Reported, not decided on.
q = NaN;
s2 = (diff(x).^2 + diff(y).^2);                       % one per step
if numel(s2) < 6, return; end
in = false(numel(s2),1); in(max(i0,1):min(i1-1,numel(s2))) = true;
if nnz(in) < 3 || nnz(~in) < 3, return; end
q = mean(s2(in)) / max(mean(s2(~in)), eps);
end

function m = inWindow(fr, wf)
if numel(wf) < 2 || (isinf(wf(1)) && isinf(wf(2))), m = isfinite(fr); return; end
m = fr >= wf(1) & fr <= wf(2) & isfinite(fr);
end

function T = emptyTrack()
T = struct('file',{},'cellIndex',{},'csID',{},'window',{},'siteUID',{},'condition',{},'trackCol',{}, ...
    'member',{},'engaged',{},'nEngage',{},'longest_s',{},'total_s',{},'fracNear',{},'minRrel',{},'mobRatio',{}, ...
    'censored',{},'nLocWin',{},'obs_s',{},'pctInside',{},'siteRadiusUm',{});
end

function S = emptySite()
S = struct('siteUID',{},'file',{},'cellIndex',{},'csID',{},'window',{},'mito',{},'condition',{}, ...
    'nTracks',{},'nMembers',{},'nEngaged',{},'fracEngaged',{},'nEngagements',{},'engagePerTrack',{}, ...
    'engagePerEngaged',{},'medianDwell_s',{},'totalDwell_s',{},'kout',{},'siteRadiusUm',{});
end

function D = emptyDwell()
D = struct('file',{},'cellIndex',{},'csID',{},'window',{},'siteUID',{},'mito',{},'condition',{}, ...
    'trackCol',{},'dwell_s',{},'entryFrame',{},'exitFrame',{},'rMin',{},'siteRadiusUm',{}, ...
    'trackObs_s',{},'censored',{});
end

function writeCSV(path, S)
if isempty(S), return; end
fid = fopen(path,'w'); if fid < 0, return; end
fn = fieldnames(S);
fprintf(fid, '%s\n', strjoin(fn', ','));
for k = 1:numel(S)
    c = cell(1,numel(fn));
    for q = 1:numel(fn)
        v = S(k).(fn{q});
        if ischar(v) || isstring(v), c{q} = csvq(char(v));
        elseif islogical(v), c{q} = sprintf('%d', v);
        elseif isempty(v), c{q} = '';
        else, c{q} = sprintf('%.6g', double(v)); end
    end
    fprintf(fid, '%s\n', strjoin(c, ','));
end
fclose(fid);
end

function s = csvq(s)
if any(s == ',') || any(s == '"'), s = ['"' strrep(s,'"','""') '"']; end
end

function v = fieldOr(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function m = med0(x), x = x(isfinite(x)); if isempty(x), m = NaN; else, m = median(x); end, end
function m = mean0(x), x = x(isfinite(x)); if isempty(x), m = NaN; else, m = mean(x); end, end
function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
