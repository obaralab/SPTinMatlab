function spt_curate_review_smoke()
%SPT_CURATE_REVIEW_SMOKE  Tool 2 "Import & Curate" review workflow (track_viewer).
%
% What is under test:
%   · REVIEW MODE — "Rejected only" draws exactly the tracks the filter threw out, so the user
%     reviews the rejects instead of hunting them among the accepted ones; "Next rejected" walks them.
%   · THE DECISION BUTTON — it names the track and is coloured for what it will DO (green KEEP /
%     red REJECT), and it is disabled until something is selected.
%   · MANUAL DECISIONS ARE DURABLE — they survive a filter re-apply, switching to another cell and
%     back, AND a batch run. They were previously wiped on every load and ignored by the batch.
%   · FEEDBACK — Apply/Export/Batch write to the activity log and restore their buttons; Export no
%     longer blocks on a modal dialog.
%   · The obsolete single XML+CSV picker is gone.
%   · FPS is live while playing.
%
% Uses a SYNTHETIC two-cell dataset in tempdir — fast, and it never reads or writes WithER.
here = fileparts(mfilename('fullpath')); addpath(here);

proj = fullfile(tempdir, sprintf('spt_curev_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(proj);
cleanup = onCleanup(@() rmdir(proj,'s')); %#ok<NASGU>
% two cells; within each, half the tracks are deliberately erratic so a threshold splits them
make_cell(proj, 'cellA', 12);
make_cell(proj, 'cellB', 8);

fig = uifigure('Visible','off','Position',[1 1 1500 900]);
pn  = uipanel(fig);
track_viewer(pn, proj, [], {}, struct('readPrefer','raw','exportSuffix','curated','preserveCloud',true));
drawnow;

bs = findobj(fig,'Type','uibutton');
pick = @(t) bs(arrayfun(@(b) contains(string(b.Text), t), bs));
bApply  = pick('Apply filter');   bToggle = pick('Toggle keep/reject');
bNextRej= pick('Next rejected');  bExport = pick('Export curated');
bBatch  = pick('Run batch');      bNext   = pick('Next >');
assert(~isempty(bApply) && ~isempty(bToggle) && ~isempty(bNextRej) && ~isempty(bExport), ...
    'expected buttons not found (Apply / Toggle / Next rejected / Export)');
bApply=bApply(1); bToggle=bToggle(1); bNextRej=bNextRej(1); bExport=bExport(1);

lg  = findobj(fig,'Type','uitextarea');
logOf = @() string(lg(arrayfun(@(t) any(contains(string(t.Value),'Curate log')), lg)).Value);
assert(~isempty(logOf()), 'no activity log pane');

%% the obsolete single-file picker is gone --------------------------------
assert(isempty(pick('Load single file')), 'the obsolete single XML+CSV loader is still present');
fprintf('single XML+CSV picker removed\n');

%% the decision button starts disabled and unnamed -----------------------
assert(strcmp(bToggle.Enable,'off'), 'decision button should be disabled with nothing selected');
assert(strcmp(bToggle.Text,'Toggle keep/reject'), 'unexpected idle label: %s', bToggle.Text);

%% split the tracks with a threshold, then review the rejects ------------
dd  = findobj(fig,'Type','uidropdown');
show = dd(arrayfun(@(d) iscell(d.Items) && any(strcmp(d.Items,'Rejected only')), dd));
assert(~isempty(show), 'Show mode dropdown (All/Kept/Rejected) not found');
show = show(1);

sl = findobj(fig,'Type','uislider');
% the disp-var slider is the one whose limits are small (variance in µm²); density is integer-scaled
[~,iv] = min(arrayfun(@(s) s.Limits(2), sl));  svar = sl(iv);
svar.Value = mean(svar.Limits);                 % cut somewhere through the distribution
cb = bApply.ButtonPushedFcn; cb(bApply, struct()); drawnow;

st = getappdata_state(fig);
assert(~isempty(st) && st.nRej > 0 && st.nKept > 0, ...
    'threshold did not split the tracks (kept %d, rejected %d)', st.nKept, st.nRej);
fprintf('filter split cellA: %d kept / %d rejected\n', st.nKept, st.nRej);
L = logOf(); assert(any(contains(L,'APPLY:')), 'Apply wrote nothing to the log');
assert(strcmp(bApply.Text,'Apply filter'), 'Apply button not restored: %s', bApply.Text);

show.Value = 'rej'; cbs = show.ValueChangedFcn; cbs(show, struct()); drawnow;
st = getappdata_state(fig);
assert(st.nShown > 0 && st.nShown <= st.nRej, ...
    '"Rejected only" drew %d tracks but only %d are rejected', st.nShown, st.nRej);
assert(all(~ismember(st.shown, st.kept)), '"Rejected only" is drawing tracks that were KEPT');
fprintf('review mode draws only rejects (%d of %d)\n', st.nShown, st.nRej);

%% Next rejected selects one, and the button names + colours the action --
cb = bNextRej.ButtonPushedFcn; cb(bNextRej, struct()); drawnow;
st = getappdata_state(fig);
assert(~isempty(st.sel), '"Next rejected" selected nothing');
assert(strcmp(bToggle.Enable,'on'), 'decision button still disabled after a selection');
assert(contains(string(bToggle.Text),'KEEP') && contains(string(bToggle.Text),num2str(st.sel)), ...
    'a REJECTED track should offer KEEP and name itself; got "%s"', bToggle.Text);
green = bToggle.BackgroundColor;
assert(green(2) > green(1) && green(2) > green(3), 'KEEP action should read green, got %s', mat2str(green,2));
fprintf('decision button: "%s"\n', bToggle.Text);

%% toggling it makes it manual, and the label says so --------------------
sel = st.sel;
cb = bToggle.ButtonPushedFcn; cb(bToggle, struct()); drawnow;
st = getappdata_state(fig);
assert(ismember(sel, st.kept), 'toggle did not keep the track');
assert(ismember(sel, st.mkeep), 'toggle did not record a manual KEEP');
L = logOf(); assert(any(contains(L,'KEEP track')), 'toggle wrote nothing to the log');
assert(contains(string(bToggle.Text),'REJECT'), 'button should now offer the opposite action');
fprintf('manual KEEP of track %d recorded\n', sel);

%% it survives a filter re-apply ----------------------------------------
cb = bApply.ButtonPushedFcn; cb(bApply, struct()); drawnow;
st = getappdata_state(fig);
assert(ismember(sel, st.kept), 'a filter re-apply discarded the manual KEEP');
fprintf('manual decision survived Apply\n');

%% ...and switching to another cell and back ----------------------------
assert(~isempty(bNext), 'no Next > cell button');
cb = bNext(1).ButtonPushedFcn; cb(bNext(1), struct()); drawnow;
stB = getappdata_state(fig);
assert(isempty(stB.mkeep) || ~ismember(sel, stB.mkeep) || ~strcmp(stB.base,'cellA'), ...
    'cellB inherited cellA''s overrides');
pv = pick('< Prev'); cb = pv(1).ButtonPushedFcn; cb(pv(1), struct()); drawnow;
st = getappdata_state(fig);
assert(strcmp(st.base,'cellA'), 'did not navigate back to cellA (on %s)', st.base);
assert(ismember(sel, st.mkeep), 'the manual KEEP was LOST by switching cells');
assert(ismember(sel, st.kept), 'the manual KEEP was not re-applied on reload');
L = logOf(); assert(any(contains(L,'restored')), 'reload did not report restoring overrides');
fprintf('manual decision survived a round trip to another cell\n');

%% Export: logs, restores its button, and pops no modal ------------------
cb = bExport.ButtonPushedFcn; cb(bExport, struct()); drawnow;
L = logOf();
assert(any(contains(L,'EXPORT')), 'Export wrote nothing to the log');
assert(any(contains(L,'manual override')), 'Export did not report honouring the manual override');
assert(strcmp(bExport.Text,'Export curated'), 'Export button not restored: %s', bExport.Text);
assert(isfile(fullfile(proj,'cellA_tracks_curated.xml')), 'no curated XML written');
assert(isempty(findobj(0,'Type','figure','-and','-regexp','Name','Export')), 'a modal export box appeared');
fprintf('export logged and non-blocking\n');

%% the batch honours manual overrides -----------------------------------
if ~isempty(bBatch)
    % load_file rescales the sliders per cell, so the round trip above reset the threshold to
    % "keep everything". Re-cut it, or the batch would keep all 12 and prove nothing.
    sl = findobj(fig,'Type','uislider');
    [~,iv] = min(arrayfun(@(s) s.Limits(2), sl)); svar = sl(iv);
    svar.Value = mean(svar.Limits);
    cb = bApply.ButtonPushedFcn; cb(bApply, struct()); drawnow;
    stPre = getappdata_state(fig);
    assert(stPre.nRej > 0, 'threshold did not re-split before the batch');
    assert(ismember(sel, stPre.kept), 'manual KEEP lost when the threshold was re-applied');
    obDir = fullfile(proj,'batchout'); mkdir(obDir);
    tx = findobj(fig,'Type','uitextarea');
    for k = 1:numel(tx)   % the batch output-folder field is an editable text area
        if isscalar(tx(k).Value) || (iscell(tx(k).Value) && numel(tx(k).Value)<=1)
            if ~any(contains(string(tx(k).Value),'Curate log')), tx(k).Value = obDir; end
        end
    end
    cb = bBatch(1).ButtonPushedFcn; cb(bBatch(1), struct()); drawnow;
    L = logOf();
    assert(any(contains(L,'BATCH')), 'batch wrote nothing to the log');
    assert(any(contains(L,'manual override')), 'batch did not report preserving manual overrides');
    kept = xml_ntracks(fullfile(obDir,'cellA_tracks_filtered.xml'));
    assert(~isnan(kept), 'batch produced no cellA output');
    % The batch must land on the same decision the interactive view showed: the threshold's keeps
    % PLUS the manual override — not all 12 (override ignored the threshold) and not the raw
    % threshold count (override dropped).
    assert(kept == stPre.nKept, 'batch kept %d but the interactive view shows %d', kept, stPre.nKept);
    assert(kept < stPre.nAll, 'batch kept every track — the threshold was not applied');
    fprintf('batch == interactive: %d of %d kept, manual override honoured\n', kept, stPre.nAll);
end

%% FPS is live ----------------------------------------------------------
sp = findobj(fig,'Type','uispinner');
fps = sp(arrayfun(@(s) isequal(s.Limits,[1 60]), sp));
assert(~isempty(fps), 'FPS spinner not found');
assert(~isempty(fps(1).ValueChangedFcn), 'FPS has no callback — it will not take effect while playing');
fprintf('FPS spinner is live\n');

close(fig);
fprintf('\nCURATE REVIEW SMOKE PASSED.\n');
end

% =====================================================================================
function st = getappdata_state(fig)
% Read the viewer's live state through the debug hook it publishes on its parent figure.
st = getappdata(fig,'tv_state');
end

function n = xml_ntracks(f)
n = NaN; if ~isfile(f), return; end
fid = fopen(f,'r'); if fid<0, return; end
cl = onCleanup(@() fclose(fid)); %#ok<NASGU>
h = fread(fid,2048,'*char')';
t = regexp(h,'nTracks\s*=\s*"(\d+)"','tokens','once');
if ~isempty(t), n = str2double(t{1}); end
end

function make_cell(dir_, base, nTracks)
% A minimal TrackMate-shaped pair: half the tracks take small regular steps, half take erratic
% ones, so a displacement-variance threshold splits them.
rng(sum(double(base)));
SPOT=0; rows=[];
xml = fopen(fullfile(dir_,[base '_tracks.xml']),'w');
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
        rows = [rows; t, SPOT, fr, fr*0.02, x, y, 100+10*rand]; %#ok<AGROW>
    end
    fprintf(xml,'  </Track>\n');
end
fprintf(xml,'</Tracks>\n'); fclose(xml);
T = array2table(rows,'VariableNames',{'TRACK_ID','SPOT_ID','FRAME','T_s','X_um','Y_um','QUALITY'});
writetable(T, fullfile(dir_,[base '_spots.csv']));
end
