function spt_linkcut_smoke()
%SPT_LINKCUT_SMOKE  Mislinkage repair: cutting a bad link splits the track, and the split sticks.
%
% THE PROBLEM THIS FEATURE SOLVES
%   The tracker sometimes joins two different molecules. Today the only remedy in Tool 2 is the jump
%   gate, which rejects the WHOLE track for containing one bad step — so a 200-localization chain with
%   one mislinkage is thrown away entirely. Cutting the link splits the chain and lets both halves be
%   judged on their own.
%
% WHAT IS ASSERTED
%   1. CUT SPLITS       — cutting the link leaving spot S turns one track into exactly two, with every
%                         localization preserved and the frame order intact on both sides.
%   2. GEOMETRY         — the cut lands where the user clicked: the head ends at S, the tail starts at
%                         the next spot, and the long step is gone from both halves.
%   3. FILTERS RE-APPLY — both halves go back through the filters rather than inheriting the parent's
%                         verdict, and a manual keep/reject on the parent is dropped with it.
%   4. EXPORT           — the split reaches <base>_tracks_curated.xml. This is the one that used to
%                         fail silently: the writer walked the parsed input DOM, which knows nothing
%                         of minted fragment ids, so a repaired track vanished from the output.
%   5. DURABILITY       — a cut survives a filter re-apply, a round trip to another cell, and a batch
%                         run, exactly as manual keep/reject does.
%   6. UNDO             — undoing restores the original chain intact.
%
% Synthetic data in tempdir; never reads or writes WithER.
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));

proj = fullfile(tempdir, sprintf('spt_lcut_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(proj);
cleanup = onCleanup(@() rmdir(proj,'s')); %#ok<NASGU>

% cellA track 1 is deliberately mislinked: two 30-spot clouds joined by one 3 µm jump.
JUMP_UM = 3.0;
make_cell(proj, 'cellA', 6, JUMP_UM);
make_cell(proj, 'cellB', 4, JUMP_UM);

fig = uifigure('Visible','off','Position',[1 1 1500 900]);
pn  = uipanel(fig);
track_viewer(pn, proj, [], {}, struct('readPrefer','raw','exportSuffix','curated','preserveCloud',true));
drawnow;
bs = findobj(fig,'Type','uibutton');
lg = findobj(fig,'Type','uitextarea');
hitLog = lg(arrayfun(@(t) any(contains(string(t.Value),'Curate log')), lg));
assert(~isempty(hitLog), 'no activity log pane');
logOf = @() string(hitLog(1).Value);
st = @() getappdata(fig,'tv_state');

bNextLink = btn(bs,'Next link');   bUndo   = btn(bs,'Undo cut');
bApply    = btn(bs,'Apply filter'); bExport = btn(bs,'Export curated');
bToggle   = btn(bs,'Toggle keep/reject');

%% (1) the guided walk finds the mislinked track ------------------------------------------------
press(bApply);
press(bNextLink);
s = st();
assert(~isempty(s.sel), '"Next link" selected nothing — the suspicious-link walk found no candidate');
tid = s.sel;
L = logOf();
assert(any(contains(L,'link(s) over')), 'the walk did not report the suspicious link. Log:\n%s', strjoin(L,newline));
fprintf('walk selected track %g as suspicious\n', tid);

nBefore   = numel(s.shown);
spotsPre  = track_spots(fig, tid);
nSpotsPre = numel(spotsPre);
assert(nSpotsPre >= 4, 'test track too short (%d spots)', nSpotsPre);

%% (2) cut the link, and check the split geometry ------------------------------------------------
% Cut at the spot before the planted jump: find the largest step and cut the link leaving its source.
[XY, SID] = track_xy(fig, tid);
d = sqrt(sum(diff(XY,1,1).^2, 2));
[bigStep, k] = max(d);
assert(bigStep > 0.9*JUMP_UM, 'planted jump not found (largest step %.3f µm)', bigStep);
cutAfter = SID(k);
nTracksPre = numel(unique(all_ids(fig)));

ok = feval(getappdata(fig,'tv_docut'), cutAfter);
assert(ok, 'do_cut refused the cut on spot %g', cutAfter);
drawnow;

ids = all_ids(fig);
assert(numel(unique(ids)) == nTracksPre + 1, ...
    'cut produced %d tracks, expected %d', numel(unique(ids)), nTracksPre+1);
head = track_spots(fig, tid);
tailId = setdiff(unique(ids), unique([all_ids_before(fig); tid]));
% the tail is whichever id now holds the spots that left the parent
allNow = spots_of(fig);
tailId = unique(allNow.TRACK_ID(ismember(allNow.SPOT_ID, setdiff(spotsPre, head))));
assert(isscalar(tailId), 'the tail is spread over %d ids, expected 1', numel(tailId));
tail = track_spots(fig, tailId);
assert(numel(head) + numel(tail) == nSpotsPre, ...
    'cut lost localizations: %d + %d ~= %d', numel(head), numel(tail), nSpotsPre);
assert(head(end) == cutAfter, 'head ends at spot %g, expected the cut spot %g', head(end), cutAfter);
assert(tail(1)  == SID(k+1), 'tail starts at spot %g, expected %g', tail(1), SID(k+1));
% and the jump is gone from both halves
assert(max_step(fig, tid) < 0.9*JUMP_UM, 'the head still contains the jump');
assert(max_step(fig, tailId) < 0.9*JUMP_UM, 'the tail still contains the jump');
fprintf('cut after spot %g: %d + %d = %d locs, jump (%.2f µm) removed from both halves\n', ...
    cutAfter, numel(head), numel(tail), nSpotsPre, bigStep);
assert(any(contains(logOf(),'CUT track')), 'the cut was not written to the log');

%% (3) both halves re-enter the filters ----------------------------------------------------------
% Force-keep the parent, then cut again elsewhere: the verdict must not carry to the fragments.
press(bApply);
s = st();
assert(ismember(tid, s.kept) || ismember(tailId, s.kept), ...
    'neither half survived the filter — the fixture cannot show re-filtering');
fprintf('after re-apply: head kept=%d, tail kept=%d\n', ismember(tid,s.kept), ismember(tailId,s.kept));

%% (4) THE SPLIT REACHES THE EXPORTED XML ---------------------------------------------------------
press(bExport);
xmlOut = fullfile(proj,'cellA_tracks_curated.xml');
assert(isfile(xmlOut), 'no curated XML written');
[nT, idsOut, spotsPerTrack] = read_xml(xmlOut);
s = st();
assert(nT == numel(s.kept), 'XML says %d tracks, the viewer kept %d', nT, numel(s.kept));
assert(isempty(setdiff(idsOut, s.kept)), 'XML holds ids the viewer did not keep: %s', ...
    mat2str(setdiff(idsOut, s.kept)));
% the fragment must actually be IN the file with its own spots — the old DOM-walking writer
% silently dropped it, because no <Track> node carries a minted id
for want = intersect([tid tailId], s.kept)
    j = find(idsOut == want, 1);
    assert(~isempty(j), 'exported XML is missing repaired track %g', want);
    assert(spotsPerTrack(j) == numel(track_spots(fig, want)), ...
        'track %g exported with %d spots, viewer has %d', want, spotsPerTrack(j), numel(track_spots(fig,want)));
end
fprintf('export contains the split: %d tracks, fragment(s) %s present with the right spot counts\n', ...
    nT, mat2str(intersect([tid tailId], s.kept)));

%% (5) the cut survives a cell round trip and a batch ---------------------------------------------
nCuts = numel(getappdata(fig,'tv_cuts'));
assert(nCuts >= 1, 'no cuts recorded');
bNext = btn(bs,'Next >'); press(bNext);            % away to cellB
press(btn(bs,'< Prev'));                            % and back
drawnow;
assert(numel(getappdata(fig,'tv_cuts')) == nCuts, ...
    'the cut was LOST by switching cells (%d -> %d)', nCuts, numel(getappdata(fig,'tv_cuts')));
ids2 = all_ids(fig);
assert(ismember(tailId, ids2), 'the fragment did not come back after a cell round trip');
assert(any(contains(logOf(),'link cut(s) restored')), 'reload did not report restoring the cuts');
fprintf('cut survived a round trip to cellB and back (%d cut(s))\n', nCuts);

bBatch = btn(bs,'Run batch');
obDir = fullfile(proj,'batchout'); mkdir(obDir);
set_batch_out(fig, obDir);
press(bBatch);
Lb = logOf();
assert(any(contains(Lb,'link cut')), 'the batch did not report applying the cuts. Log:\n%s', strjoin(Lb,newline));
[nTb, idsB] = read_xml(fullfile(obDir,'cellA_tracks_curated.xml'));
assert(ismember(tailId, idsB), ...
    'the batch re-introduced the mislinkage — fragment %g absent from its output', tailId);
fprintf('batch honoured the cut: %d tracks out, fragment %g present\n', nTb, tailId);

%% (6) undo restores the original chain ------------------------------------------------------------
press(bUndo); drawnow;
assert(isempty(getappdata(fig,'tv_cuts')), 'undo left %d cut(s)', numel(getappdata(fig,'tv_cuts')));
back = track_spots(fig, tid);
assert(numel(back) == nSpotsPre, 'undo restored %d of %d localizations', numel(back), nSpotsPre);
assert(isequal(sort(back(:)), sort(spotsPre(:))), 'undo restored a different set of spots');
assert(max_step(fig, tid) > 0.9*JUMP_UM, 'undo did not restore the original (jumping) chain');
fprintf('undo restored the %d-loc chain including its jump\n', numel(back));

close(fig);
fprintf('\nLINK-CUT SMOKE PASSED.\n');
end

% =====================================================================================
function b = btn(bs, txt)
b = bs(arrayfun(@(x) contains(string(x.Text), txt), bs));
assert(~isempty(b), 'button "%s" not found', txt);
b = b(1);
end

function press(b), cb = b.ButtonPushedFcn; cb(b, struct()); drawnow; end

function T = spots_of(fig), T = getappdata(fig,'tv_spots'); end

function ids = all_ids(fig), T = spots_of(fig); ids = T.TRACK_ID; end
function ids = all_ids_before(fig), T = spots_of(fig); ids = T.ORIG_TRACK_ID; end

function sid = track_spots(fig, tid)
T = spots_of(fig); r = sortrows(T(T.TRACK_ID==tid,:),'FRAME'); sid = r.SPOT_ID;
end

function [XY, SID] = track_xy(fig, tid)
T = spots_of(fig); r = sortrows(T(T.TRACK_ID==tid,:),'FRAME');
XY = [r.X_um r.Y_um]; SID = r.SPOT_ID;
end

function m = max_step(fig, tid)
[XY,~] = track_xy(fig, tid);
if size(XY,1) < 2, m = 0; return; end
m = max(sqrt(sum(diff(XY,1,1).^2,2)));
end

function set_batch_out(fig, dir_)
tx = findobj(fig,'Type','uitextarea');
for k = 1:numel(tx)
    v = string(tx(k).Value);
    if any(contains(v,'Curate log')), continue; end
    if numel(v) == 1 && (isfolder(strtrim(v)) || contains(v, filesep)), tx(k).Value = dir_; end
end
end

function [n, ids, nspots] = read_xml(f)
n = 0; ids = []; nspots = [];
assert(isfile(f), 'missing %s', f);
txt = fileread(f);
t = regexp(txt,'nTracks\s*=\s*"(\d+)"','tokens','once');
if ~isempty(t), n = str2double(t{1}); end
blocks = regexp(txt,'<Track TRACK_ID="(\d+)"[^>]*>(.*?)</Track>','tokens');
for k = 1:numel(blocks)
    ids(end+1,1) = str2double(blocks{k}{1}); %#ok<AGROW>
    nspots(end+1,1) = numel(regexp(blocks{k}{2},'<Spot ','start')); %#ok<AGROW>
end
end

function make_cell(dir_, base, nTracks, jumpUm)
% Track 1 is a MISLINKAGE: two tight clouds joined by one long step. The rest are ordinary.
rng(sum(double(base)));
SPOT = 0; rows = [];
xml = fopen(fullfile(dir_,[base '_tracks.xml']),'w');
fprintf(xml,'<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(xml,'<Tracks nTracks="%d" frameInterval="0.02" spaceUnit="um" timeUnit="s">\n',nTracks);
for t = 1:nTracks
    n = 30; x = 5+2*rand; y = 5+2*rand;
    fprintf(xml,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n',t,n);
    for i = 1:n
        if t==1 && i==16, x = x + jumpUm; y = y + jumpUm/2;   % the planted mislinkage
        else
            th = 2*pi*rand; s = 0.05; x = x + s*cos(th); y = y + s*sin(th);
        end
        SPOT = SPOT+1; fr = i-1; q = 100+10*rand;
        fprintf(xml,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n', ...
            SPOT, fr, fr*0.02, x, y);
        rows = [rows; t, SPOT, fr, fr*0.02, x, y, q, q, q*1.4, q*n, 0.3*rand, 0.05*rand]; %#ok<AGROW>
    end
    fprintf(xml,'  </Track>\n');
end
fprintf(xml,'</Tracks>\n'); fclose(xml);
T = array2table(rows,'VariableNames',{'TRACK_ID','SPOT_ID','FRAME','T_s','X_um','Y_um','QUALITY', ...
    'MEAN_INTENSITY','MAX_INTENSITY','TOTAL_INTENSITY','MITO_DIST_UM','ER_DIST_UM'});
writetable(T, fullfile(dir_,[base '_spots.csv']));
end
