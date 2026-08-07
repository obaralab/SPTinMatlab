function spt_batch_overwrite_smoke()
%SPT_BATCH_OVERWRITE_SMOKE  The batch filter must never destroy the file it read.
%
% THE BUG THIS PINS DOWN
%   track_viewer's batch wrote '<base>_tracks_filtered.xml' hardcoded, ignoring S.exportSuffix.
%   Tool 2 runs it with readPrefer='filtered' (it READS Tool 1's '_tracks_filtered.xml') and the
%   batch output-folder box pre-fills to that same tracks/ folder. So "Run batch filter" with the
%   defaults read Tool 1's tracking output and wrote the twice-filtered result straight back over
%   it — Tool 1's tracks gone, unrecoverably, with no warning. Re-running the batch then filtered
%   the already-filtered tracks again, compounding it.
%
% WHAT IS ASSERTED
%   1. OVERWRITE — with Tool 2's real settings and the output folder left at the default (the input
%      folder), the input '_tracks_filtered.xml' and '_spots_filtered.csv' come out byte-identical.
%   2. FULL OUTPUT SET — the batch writes _tracks_<suffix>.xml, _spots_<suffix>.csv,
%      _track_metrics.csv and _filter_log.csv, the same set the interactive export writes. It used
%      to write no spots CSV and no metrics at all.
%   3. COLLISION GUARD — configured so the output name EQUALS the input name, the batch refuses the
%      write, says so in the log, and leaves the input intact.
%   4. HAND-OFF — TrackImporter_direct pairs '_tracks_curated.xml' with '_spots_curated.csv'
%      (its candidate list omitted the curated CSV entirely).
%
% Synthetic data in tempdir; never reads or writes WithER.
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));

proj = fullfile(tempdir, sprintf('spt_batov_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(proj);
cleanup = onCleanup(@() rmdir(proj,'s')); %#ok<NASGU>

%% (1) Tool 2's real configuration, output folder left at the default ---------------------------
% Tool 1's output: the '_filtered' pair. This is what must survive.
make_cell(proj, 'cellA', 12, '_filtered');
make_cell(proj, 'cellB', 8,  '_filtered');
inXml = fullfile(proj,'cellA_tracks_filtered.xml');
inCsv = fullfile(proj,'cellA_spots_filtered.csv');
pre   = struct('xml', fingerprint(inXml), 'csv', fingerprint(inCsv));
nPre  = xml_ntracks(inXml);
fprintf('Tool 1 input: cellA_tracks_filtered.xml, %d tracks, %s\n', nPre, pre.xml);

[fig, bs, logOf] = open_viewer(proj, struct( ...
    'readPrefer','filtered','exportSuffix','curated','preserveCloud',true));
cut_and_apply(fig, bs);
% Deliberately do NOT touch the batch output-folder box: the default IS the input folder, and that
% default is half the bug. Confirm that before running, so the test cannot pass by accident.
obox = batch_out_box(fig);
assert(~isempty(obox), 'could not find the batch output-folder box');
assert(same_dir(strtrim(strjoin(string(obox.Value),'')), proj), ...
    'batch output folder does not default to the input folder — this test would not exercise the bug');
fprintf('batch output folder defaults to the input folder (as shipped)\n');

run_batch(fig, bs);
L = logOf();
assert(any(contains(L,'BATCH')), 'batch wrote nothing to the log');

assert(isfile(inXml), 'THE BATCH DELETED Tool 1''s _tracks_filtered.xml');
assert(strcmp(fingerprint(inXml), pre.xml), ...
    'THE BATCH OVERWROTE Tool 1''s _tracks_filtered.xml (%s -> %s, %d -> %d tracks)', ...
    pre.xml, fingerprint(inXml), nPre, xml_ntracks(inXml));
assert(strcmp(fingerprint(inCsv), pre.csv), 'the batch overwrote Tool 1''s _spots_filtered.csv');
fprintf('Tool 1''s input pair survived the batch byte-identical\n');

%% (2) the batch writes the same file set as the interactive export ------------------------------
want = {'cellA_tracks_curated.xml','cellA_spots_curated.csv', ...
        'cellA_track_metrics.csv','cellA_filter_log.csv', ...
        'cellB_tracks_curated.xml','cellB_spots_curated.csv'};
for k = 1:numel(want)
    assert(isfile(fullfile(proj,want{k})), 'batch did not write %s', want{k});
end
nOut = xml_ntracks(fullfile(proj,'cellA_tracks_curated.xml'));
assert(~isnan(nOut) && nOut > 0 && nOut < nPre, ...
    'batch kept %d of %d — expected a strict subset', nOut, nPre);
% the spots CSV must keep the WHOLE cloud (preserveCloud), blanking TRACK_ID for dropped tracks
Sc = readtable(fullfile(proj,'cellA_spots_curated.csv'), 'TextType','string');
Si = readtable(inCsv, 'TextType','string');
assert(height(Sc) == height(Si), ...
    'curated spots CSV has %d rows, input had %d — the localization cloud was not preserved', ...
    height(Sc), height(Si));
tidOut = numel(unique(rmmissing(double(Sc.TRACK_ID))));
assert(tidOut == nOut, 'spots CSV names %d tracks but the XML holds %d', tidOut, nOut);
tm = readtable(fullfile(proj,'cellA_track_metrics.csv'));
assert(ismember('KEEP', tm.Properties.VariableNames), 'track metrics CSV has no KEEP column');
assert(sum(tm.KEEP ~= 0) == nOut, 'KEEP flags %d tracks, the XML holds %d', sum(tm.KEEP~=0), nOut);
fprintf('batch wrote the full set: %d tracks kept of %d, cloud preserved (%d rows)\n', ...
    nOut, nPre, height(Sc));
close(fig);

%% (4) the HTML report — nothing was checking it existed, let alone parsed ---------------------
% "Run batch filter + HTML report" is one button; the report is half of what it promises, and a
% silent failure to write it looks identical to a successful run.
rep = fullfile(proj,'batch_filter_report.html');
assert(isfile(rep), 'the batch wrote no batch_filter_report.html');
h = fileread(rep);
info = dir(rep);
fprintf('HTML report: %d bytes\n', info.bytes);
assert(info.bytes > 500, 'the report is suspiciously small (%d bytes)', info.bytes);

% well-formed enough to open
for tag = {'<!DOCTYPE html>','</html>','</body>','<table>','</table>'}
    assert(contains(h, tag{1}), 'the report is missing %s', tag{1});
end
assert(count(h,'<table>') == count(h,'</table>'), 'unbalanced <table> in the report');
assert(count(h,'<tr>')    == count(h,'</tr>'),    'unbalanced <tr> in the report');

% it must name the cell it processed and report the SAME counts the batch logged
assert(contains(h,'cellA'), 'the report does not name the cell it filtered');
kept = numel(regexp(fileread(fullfile(proj,'cellA_tracks_curated.xml')),'<Track ','match'));
assert(contains(h, sprintf('%d', kept)), ...
    'the report does not carry the kept-track count (%d) the batch actually wrote', kept);

% and the thresholds it claims to have applied must be the ones on screen
sp = findobj(fig,'Type','uispinner');
dv = sp(arrayfun(@(x) isequal(x.Limits,[0 100]) || isequal(x.Limits,[0.1 20]), sp));
assert(contains(h,'Max disp variance') && contains(h,'Max local density'), ...
    'the report does not state the thresholds it applied');
fprintf('HTML report: well-formed, names the cell, carries the kept count and the thresholds\n');


%% (3) collision guard: output name == input name -> refuse, do not destroy ----------------------
% Read the filtered pair AND export under the 'filtered' suffix, into the same folder. The names
% collide exactly. Nothing in the shipped app is wired this way now; the guard is what makes that
% permanent rather than a property of today's two suffix strings.
[fig2, bs2, logOf2] = open_viewer(proj, struct( ...
    'readPrefer','filtered','exportSuffix','filtered','preserveCloud',true));
cut_and_apply(fig2, bs2);
run_batch(fig2, bs2);
L2 = logOf2();
assert(any(contains(L2,'SKIPPED')) && any(contains(L2,'overwrite')), ...
    'a colliding batch did not report skipping the write. Log:\n%s', strjoin(L2, newline));
assert(strcmp(fingerprint(inXml), pre.xml), ...
    'the collision guard failed — the input was overwritten anyway');
fprintf('collision refused and logged; input still intact\n');
% ...and the refused run must not have BLANKED the report the successful run wrote. Writing it
% unconditionally produced a valid-looking "Files: 0" page on top of a real summary.
h2 = fileread(rep);
assert(contains(h2,'cellA') && ~contains(h2,'Files: 0'), ...
    'the refused batch overwrote the good HTML report with an empty one');
fprintf('the refused run kept the previous report intact (%d bytes)\n', numel(h2));
close(fig2);

%% (4) the importer pairs the curated XML with the curated CSV -----------------------------------
% Isolate the curated pair so the ONLY CSV that can satisfy it is '_spots_curated.csv'. Before the
% fix the candidate list held no curated entry, so this folder imported with no intensities at all.
iso = fullfile(proj,'iso'); mkdir(iso);
copyfile(fullfile(proj,'cellA_tracks_curated.xml'), fullfile(iso,'cellA_tracks_curated.xml'));
copyfile(fullfile(proj,'cellA_spots_curated.csv'), fullfile(iso,'cellA_spots_curated.csv'));
T = TrackImporter_direct(iso, 'Pattern','*_tracks_curated.xml', 'Save',false, 'Verbose',false);
assert(~isempty(T), 'importer built nothing from the curated pair');
assert(~isempty(T(1).intens), ...
    'importer found no spots CSV for a curated-only folder — intensities, MITO_DIST_UM and ER_DIST_UM all lost');
assert(~isempty(T(1).allSpots) && numel(T(1).allSpots.FRAME) == height(Sc), ...
    'allSpots holds %d detections, the curated CSV has %d', ...
    numel(T(1).allSpots.FRAME), height(Sc));
% the contact-site stages key off these two, so a mispaired CSV would quietly disarm Tool 3
assert(~isempty(T(1).mitoDist) && any(isfinite(T(1).mitoDist(:))), 'MITO_DIST_UM did not come through');
assert(~isempty(T(1).erDist)   && any(isfinite(T(1).erDist(:))),   'ER_DIST_UM did not come through');
% ...and the keyed storage the readers actually prefer (step 2 of the reference-channel migration).
% The flat pair above is still written, so a build made here opens in a tool from before the change.
assert(isfield(T,'dist') && isstruct(T(1).dist), 'importer wrote no keyed distance container');
assert(isequaln(T(1).dist.mito, T(1).mitoDist), 'dist.mito disagrees with mitoDist');
assert(isequaln(T(1).dist.er,   T(1).erDist),   'dist.er disagrees with erDist');
assert(isequaln(T(1).allSpots.DIST.mito, T(1).allSpots.MITODIST), 'allSpots.DIST.mito disagrees');
assert(isequaln(T(1).allSpots.DIST.er,   T(1).allSpots.ERDIST),   'allSpots.DIST.er disagrees');
% and both stores must agree through the accessor, tracked and cloud
for kk = {'mito','er'}
    assert(isequaln(cs_channel_dist(T(1),kk{1},'tracked'), reshape(T(1).(cs_channel_fields(kk{1}).mat),[],1)), ...
        '%s: accessor and flat field disagree (tracked)', kk{1});
    assert(cs_channel_has(T(1),kk{1}) && cs_channel_has(T(1),kk{1},'cloud'), '%s: not seen as present', kk{1});
end
fprintf('importer paired _tracks_curated.xml with _spots_curated.csv (%d tracks, %d detections)\n', ...
    numel(T(1).lengths), numel(T(1).allSpots.FRAME));

fprintf('\nBATCH-OVERWRITE SMOKE PASSED.\n');
end

% =====================================================================================
function [fig, bs, logOf] = open_viewer(proj, opts)
fig = uifigure('Visible','off','Position',[1 1 1500 900]);
pn  = uipanel(fig);
track_viewer(pn, proj, [], {}, opts);
drawnow;
bs = findobj(fig,'Type','uibutton');
lg = findobj(fig,'Type','uitextarea');
hit = lg(arrayfun(@(t) any(contains(string(t.Value),'Curate log')), lg));
assert(~isempty(hit), 'no activity log pane');
logOf = @() string(hit(1).Value);
end

function b = btn(bs, txt)
b = bs(arrayfun(@(x) contains(string(x.Text), txt), bs));
assert(~isempty(b), 'button "%s" not found', txt);
b = b(1);
end

function cut_and_apply(fig, bs)
% Put the displacement-variance threshold mid-range so the filter splits the tracks, then apply.
sl = findobj(fig,'Type','uislider');
[~,iv] = min(arrayfun(@(s) s.Limits(2), sl));
sl(iv).Value = mean(sl(iv).Limits);
bA = btn(bs,'Apply filter'); cb = bA.ButtonPushedFcn; cb(bA, struct()); drawnow;
st = getappdata(fig,'tv_state');
assert(~isempty(st) && st.nRej > 0 && st.nKept > 0, ...
    'threshold did not split the tracks (kept %d, rejected %d) — the batch would prove nothing', ...
    st.nKept, st.nRej);
end

function run_batch(fig, bs)
bB = btn(bs,'Run batch'); cb = bB.ButtonPushedFcn; cb(bB, struct()); drawnow;
end

function h = batch_out_box(fig)
% The batch output folder is an editable text area holding a single path (not the log).
h = [];
tx = findobj(fig,'Type','uitextarea');
for k = 1:numel(tx)
    v = string(tx(k).Value);
    if any(contains(v,'Curate log')), continue; end
    if numel(v) == 1 && (isfolder(strtrim(v)) || contains(v, filesep)), h = tx(k); return; end
end
end

function tf = same_dir(a, b)
tf = false;
try
    tf = strcmp(char(java.io.File(char(a)).getCanonicalPath()), ...
                char(java.io.File(char(b)).getCanonicalPath()));
catch
    tf = strcmp(char(a), char(b));
end
end

function s = fingerprint(f)
% size + content hash: catches a rewrite even when the byte count happens to match.
s = 'MISSING';
if ~isfile(f), return; end
d = dir(f);
fid = fopen(f,'r'); if fid < 0, return; end
cl = onCleanup(@() fclose(fid)); %#ok<NASGU>
b = fread(fid, Inf, '*uint8');
h = uint32(mod(sum(double(b) .* mod((1:numel(b))',257)), 2^32));
s = sprintf('%dB/%08x', d.bytes, h);
end

function n = xml_ntracks(f)
n = NaN; if ~isfile(f), return; end
fid = fopen(f,'r'); if fid<0, return; end
cl = onCleanup(@() fclose(fid)); %#ok<NASGU>
h = fread(fid,2048,'*char')';
t = regexp(h,'nTracks\s*=\s*"(\d+)"','tokens','once');
if ~isempty(t), n = str2double(t{1}); end
end

function make_cell(dir_, base, nTracks, suffix)
% A minimal TrackMate-shaped pair under the given suffix ('' or '_filtered'): half the tracks step
% smoothly, half erratically, so a displacement-variance threshold splits them.
rng(sum(double(base)));
SPOT=0; rows=[];
xml = fopen(fullfile(dir_,[base '_tracks' suffix '.xml']),'w');
fprintf(xml,'<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(xml,'<Tracks nTracks="%d" frameInterval="0.02" spaceUnit="um" timeUnit="s">\n',nTracks);
for t = 1:nTracks
    n = 20; x = 5+2*rand; y = 5+2*rand;
    erratic = mod(t,2)==0;
    fprintf(xml,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n',t,n);
    for i = 1:n
        if erratic, s = 0.02 + 0.6*(rand>0.7); else, s = 0.05; end
        th = 2*pi*rand; x = x + s*cos(th); y = y + s*sin(th);
        SPOT = SPOT+1; fr = i-1;
        fprintf(xml,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n', SPOT,fr,fr*0.02,x,y);
        % Carry the columns the importer actually reads: the three intensities it stores in
        % Tracks.intens, plus the mito/ER distances. Without them a paired CSV proves nothing —
        % attach_intensities would return empty for a missing column, not a missing file.
        q = 100+10*rand;
        rows = [rows; t, SPOT, fr, fr*0.02, x, y, q, q, q*1.4, q*n, 0.3*rand, 0.05*rand]; %#ok<AGROW>
    end
    fprintf(xml,'  </Track>\n');
end
fprintf(xml,'</Tracks>\n'); fclose(xml);
T = array2table(rows,'VariableNames',{'TRACK_ID','SPOT_ID','FRAME','T_s','X_um','Y_um','QUALITY', ...
    'MEAN_INTENSITY','MAX_INTENSITY','TOTAL_INTENSITY','MITO_DIST_UM','ER_DIST_UM'});
writetable(T, fullfile(dir_,[base '_spots' suffix '.csv']));
end
