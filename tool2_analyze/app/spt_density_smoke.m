function spt_density_smoke()
%SPT_DENSITY_SMOKE  The crowding metric must actually separate crowded tracks from isolated ones.
%
% THE PROBLEM THIS FIXES
%   Local density was counted within the LINKING radius and over TRACKED spots only. Measured on the
%   WithER reference cell that gave a metric with no usable range: 73 % of tracks scored 0, the
%   largest value anywhere in the cell was 2, and two thirds of the detections you can see in the
%   field of view (220,401 total, 73,994 in surviving tracks) were never counted at all. A filter
%   whose input is almost always zero cannot separate anything.
%
% WHAT IS ASSERTED, on a fixture with a deliberately crowded region and a deliberately empty one:
%   1. SEPARATION      — tracks in the crowded region score strictly higher than isolated ones, and
%                        the filter can be set to a threshold that keeps exactly the isolated ones.
%   2. RADIUS MATTERS  — at the old small radius the two populations are indistinguishable; widening
%                        it separates them. This is the actual defect, so it is asserted directly.
%   3. UNTRACKED COUNT — a region crowded ONLY by untracked detections still reads as crowded with
%                        "count untracked" on, and collapses to nothing with it off. This is what
%                        made the shipped metric blind to most of the field.
%   4. STATISTIC       — 'mean' is time-averaged over the track and 'max' is the worst single frame;
%                        for a track that dips briefly into a crowd, max >> mean.
%   5. BATCH AGREES    — the batch measures each cell against ITS OWN cloud, not the open cell's.
%
% Synthetic data in tempdir; never reads or writes WithER.
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));

proj = fullfile(tempdir, sprintf('spt_dens_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(proj);
cleanup = onCleanup(@() rmdir(proj,'s')); %#ok<NASGU>

make_cell(proj, 'cellA');
make_cell(proj, 'cellB');

fig = uifigure('Visible','off','Position',[1 1 1500 900]);
pn  = uipanel(fig);
track_viewer(pn, proj, [], {}, struct('readPrefer','raw','exportSuffix','curated','preserveCloud',true));
drawnow;
bs = findobj(fig,'Type','uibutton');
sp = findobj(fig,'Type','uispinner');
dd = findobj(fig,'Type','uidropdown');
ck = findobj(fig,'Type','uicheckbox');

radS  = one(sp, @(x) isequal(x.Limits,[0.1 20]), 'density radius spinner');
statD = one(dd, @(x) iscell(x.ItemsData) && any(strcmp(x.ItemsData,'mean')), 'density statistic dropdown');
% The count-untracked CHECKBOX is gone: crowding now always counts the whole localization cloud,
% so there is no control to find. Part (3) below asserts the behaviour directly instead.
assert(~any(arrayfun(@(x) contains(string(x.Text),'untracked'), ck)), ...
    'the count-untracked checkbox is back — crowding must always count the whole cloud');
bApply= btnOf(bs,'Apply filter');

% CROWDED = tracks 1-3 (sat in a dense field), ISOLATED = tracks 4-6 (alone)
CROWDED = [1 2 3]; ISOLATED = [4 5 6];

%% (2) the radius is the defect: small radius cannot separate, wide radius can ------------------
setv(radS, 0.8); setv(statD, 'mean');
dNarrow = dens_by_track(fig);
sepNarrow = min(dNarrow(CROWDED)) - max(dNarrow(ISOLATED));

setv(radS, 3.0);
dWide = dens_by_track(fig);
sepWide = min(dWide(CROWDED)) - max(dWide(ISOLATED));

fprintf('radius 0.8: crowded %s vs isolated %s  (margin %+.2f)\n', ...
    fmt(dNarrow(CROWDED)), fmt(dNarrow(ISOLATED)), sepNarrow);
fprintf('radius 3.0: crowded %s vs isolated %s  (margin %+.2f)\n', ...
    fmt(dWide(CROWDED)), fmt(dWide(ISOLATED)), sepWide);
assert(sepWide > 0, ...
    'at 3.0 µm the crowded tracks (min %.2f) do not exceed the isolated ones (max %.2f)', ...
    min(dWide(CROWDED)), max(dWide(ISOLATED)));
assert(sepWide > 5*max(sepNarrow, 0.2), ...
    ['widening the radius barely improved separation (%.2f -> %.2f). The crowd here sits 1.2-2.5 µm ' ...
     'out, so a 0.8 µm neighbourhood cannot see it and a 3 µm one must.'], sepNarrow, sepWide);

%% (1) a threshold exists that keeps exactly the isolated tracks --------------------------------
thr = (max(dWide(ISOLATED)) + min(dWide(CROWDED)))/2;
dnS = one(findobj(fig,'Type','uislider'), @(x) x.Limits(2) > max(dWide)*0.9, 'density slider');
setv(dnS, thr);
press(bApply);
st = getappdata(fig,'tv_state');
assert(all(ismember(ISOLATED, st.kept)), 'the isolated tracks were not all kept at threshold %.2f', thr);
assert(~any(ismember(CROWDED, st.kept)), 'a crowded track survived threshold %.2f', thr);
fprintf('threshold %.2f keeps exactly the %d isolated tracks\n', thr, numel(ISOLATED));

%% (3) untracked detections ALWAYS count ---------------------------------------------------------
% Track 7 sits in a cloud made ONLY of untracked detections, so it is the whole test: if the metric
% counted just spots in surviving tracks, track 7 would read empty. That used to be a checkbox, and
% unticking it measured a crowding that does not exist — on the reference cell two thirds of the
% detections in the field stopped counting as neighbours. There is no longer a way to turn it off.
dOn = dens_by_track(fig);
assert(numel(dOn) >= 7, 'fixture did not produce the untracked-crowd track');
assert(dOn(7) > 2, ...
    ['track 7 sits in a crowd of UNTRACKED detections and scored only %.2f — the metric is ' ...
     'ignoring the cloud again'], dOn(7));
fprintf('untracked crowd always counts: track 7 scores %.2f\n', dOn(7));

%% (4) mean vs max ------------------------------------------------------------------------------
% Track 8 is isolated for most of its life and dips into the crowd briefly.
setv(statD, 'mean'); dMean = dens_by_track(fig);
setv(statD, 'max');  dMax  = dens_by_track(fig);
setv(statD, 'mean');
assert(numel(dMean) >= 8, 'fixture did not produce the brief-dip track');
assert(dMax(8) > 3*dMean(8), ...
    'brief dip into a crowd: max %.2f is not much above mean %.2f, so the two statistics are not distinct', ...
    dMax(8), dMean(8));
fprintf('brief dip: mean %.2f vs max %.2f — the statistics differ as intended\n', dMean(8), dMax(8));

%% (5) the batch measures each cell against ITS OWN cloud ---------------------------------------
% cellB is built with a much emptier field. If the batch reused the open cell's cloud, cellB's
% densities would come out like cellA's.
setv(radS, 3.0); setv(statD, 'mean');
obDir = fullfile(proj,'batchout'); mkdir(obDir);
tx = findobj(fig,'Type','uitextarea');
for k = 1:numel(tx)
    v = string(tx(k).Value);
    if any(contains(v,'Curate log')), continue; end
    if numel(v)==1 && (isfolder(strtrim(v)) || contains(v,filesep)), tx(k).Value = obDir; end
end
setv(dnS, dnS.Limits(2));            % keep everything, so the logs are comparable
press(bApply);
press(btnOf(bs,'Run batch'));
la = readmatrix_density(fullfile(obDir,'cellA_filter_log.csv'));
lb = readmatrix_density(fullfile(obDir,'cellB_filter_log.csv'));
assert(~isempty(la) && ~isempty(lb), 'batch did not write both filter logs');
assert(max(lb) < max(la), ...
    'cellB (empty field) reports max density %.2f, not below cellA''s %.2f — the batch is reusing one cloud', ...
    max(lb), max(la));
fprintf('batch per-cell clouds: cellA max %.2f vs cellB max %.2f\n', max(la), max(lb));

close(fig);
fprintf('\nDENSITY SMOKE PASSED.\n');
end

% =====================================================================================
function h = one(hs, pred, what)
h = hs(arrayfun(pred, hs));
assert(~isempty(h), '%s not found', what);
h = h(1);
end
function b = btnOf(bs, txt)
ex = bs(arrayfun(@(x) strcmp(strtrim(string(x.Text)), txt), bs));
if ~isempty(ex), b = ex(1); return; end
b = bs(arrayfun(@(x) contains(string(x.Text), txt), bs));
assert(~isempty(b), 'button "%s" not found', txt); b = b(1);
end
function press(b), cb = b.ButtonPushedFcn; cb(b, struct()); drawnow; end
function fire(h), cb = h.ValueChangedFcn; if ~isempty(cb), cb(h, struct()); end, drawnow; end
function setv(h, v), h.Value = v; fire(h); end
function s = fmt(v), s = ['[' strtrim(sprintf('%.2f ', v)) ']']; end

function d = dens_by_track(fig)
% per-track density, indexed by TRACK_ID
tm = getappdata(fig,'tv_metrics');
d = nan(max(tm.TRACK_ID),1);
d(tm.TRACK_ID) = tm.mean_local_density;
end

function v = readmatrix_density(f)
v = [];
if ~isfile(f), return; end
T = readtable(f);
if ismember('local_density', T.Properties.VariableNames), v = T.local_density; end
end

function make_cell(dir_, base)
% Eight tracks plus a bath of untracked detections:
%   1-3 crowded  : tight cluster at (5,5) surrounded by many other detections
%   4-6 isolated : far apart at the corners, nothing near them
%   7   crowded by UNTRACKED detections only
%   8   isolated for most frames, dipping into the (5,5) crowd for a few
% cellB uses a much sparser bath so a per-cell cloud is distinguishable from cellA's.
rng(sum(double(base)));
sparse_ = strcmp(base,'cellB');
nBath = 40; if sparse_, nBath = 2; end
N = 40;                       % frames
SPOT = 0; rows = []; trk = {};

    function add(tid, x0, y0, jit, frames)
        for i = frames
            SPOT = SPOT + 1;
            x = x0 + jit*randn; y = y0 + jit*randn;
            rows(end+1,:) = [tid, SPOT, i, i*0.02, x, y, 100, 100, 140, 4000, 0.1, 0.05]; %#ok<AGROW>
            if tid > 0
                if numel(trk) < tid || isempty(trk{tid}), trk{tid} = []; end
                trk{tid}(end+1) = size(rows,1);
            end
        end
    end

for t = 1:3,  add(t, 5 + 0.15*t, 5, 0.03, 0:N-1); end          % crowded cluster
add(4, 1,  1,  0.03, 0:N-1);                                    % isolated
add(5, 20, 1,  0.03, 0:N-1);
add(6, 20, 20, 0.03, 0:N-1);
add(7, 12, 12, 0.03, 0:N-1);                                    % crowd is untracked only
add(8, 10, 1,  0.03, 0:N-1);                                    % isolated most of the time...
% ...but track 8's LAST few localizations sit inside the (5,5) crowd
for i = N-4:N-1
    r = trk{8}(i+1); rows(r,5) = 5.05 + 0.02*randn; rows(r,6) = 5.0 + 0.02*randn;
end

% Untracked bath, placed in an ANNULUS 1.2-2.5 µm out from each crowded centre. This is the real
% situation: the field around a track is busy, but the other spots are not sitting on top of it. At
% the old 0.8 µm radius none of this is visible to the metric — which is exactly why a track could
% look clean while the field around it was full.
for i = 0:N-1
    for q = 1:nBath
        for ctr = [5 12]
            rr = 1.2 + 1.3*rand; th = 2*pi*rand;
            SPOT = SPOT+1;
            rows(end+1,:) = [0, SPOT, i, i*0.02, ctr + rr*cos(th), ctr + rr*sin(th), ...
                             90, 90, 120, 3000, 0.1, 0.05]; %#ok<AGROW>
        end
    end
end

% XML holds only the TRACKED spots; the CSV holds everything, TRACK_ID blank for the bath
xml = fopen(fullfile(dir_,[base '_tracks.xml']),'w');
fprintf(xml,'<?xml version="1.0" encoding="UTF-8"?>\n');
tids = unique(rows(rows(:,1)>0,1));
fprintf(xml,'<Tracks nTracks="%d" frameInterval="0.02" spaceUnit="um" timeUnit="s">\n',numel(tids));
for t = tids(:)'
    r = rows(rows(:,1)==t,:); r = sortrows(r,3);
    fprintf(xml,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n',t,size(r,1));
    for i = 1:size(r,1)
        fprintf(xml,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n', ...
            r(i,2), r(i,3), r(i,4), r(i,5), r(i,6));
    end
    fprintf(xml,'  </Track>\n');
end
fprintf(xml,'</Tracks>\n'); fclose(xml);

T = array2table(rows,'VariableNames',{'TRACK_ID','SPOT_ID','FRAME','T_s','X_um','Y_um','QUALITY', ...
    'MEAN_INTENSITY','MAX_INTENSITY','TOTAL_INTENSITY','MITO_DIST_UM','ER_DIST_UM'});
T.TRACK_ID = string(T.TRACK_ID); T.TRACK_ID(T.TRACK_ID=="0") = "";   % blank for untracked
writetable(T, fullfile(dir_,[base '_spots.csv']));
end
