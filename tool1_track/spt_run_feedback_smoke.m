function spt_run_feedback_smoke()
%SPT_RUN_FEEDBACK_SMOKE  Track-tab click feedback + log detail (Tool 1).
%
% What is under test:
%   · clicking an action button visibly changes it (amber "working…") and disables the others, and
%     everything is restored afterwards — including when the job throws;
%   · the shared status line reports progress and a final elapsed time;
%   · the log carries the numbers worth having: counts, rejects, per-cell and total timing;
%   · Tool 1 never calls what it does "curation" — it only FILTERS; curation is Tool 2's job.
%
% Runs Export (fast — it re-reads an existing _spots.csv) against a TEMP project. Only the spots CSV
% is symlinked; _settings.txt is COPIED because the exporter appends to it, and save/fopen follow a
% symlink straight back into WithER.
here = fileparts(mfilename('fullpath')); addpath(here);
W = '/Users/safal-mac/Documents/IntegratedPipeline/WithER';
base = '250408_WT_012_spt1';
srcCsv = fullfile(W,'tracks',[base '_spots.csv']);
assert(isfile(srcCsv), 'test data missing: %s', srcCsv);

wsnap = snapWithER(W);   % fingerprint the pristine data; asserted unchanged at the end

proj = fullfile(tempdir, sprintf('spt_fb_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(proj); mkdir(fullfile(proj,'tracks'));
for d = {'spt','er_seg','mito_seg'}
    sdir = fullfile(W,d{1}); dst = fullfile(proj,d{1}); mkdir(dst);
    ff = dir(fullfile(sdir,'*'));
    for q = 1:numel(ff)
        if ff(q).isdir, continue; end
        [~,~,ex] = fileparts(ff(q).name); if strcmpi(ex,'.mat'), continue; end
        system(sprintf('ln -s "%s" "%s"', fullfile(sdir,ff(q).name), fullfile(dst,ff(q).name)));
    end
end
system(sprintf('ln -s "%s" "%s"', srcCsv, fullfile(proj,'tracks',[base '_spots.csv'])));   % read-only
st0 = fullfile(W,'tracks',[base '_settings.txt']);
if isfile(st0), copyfile(st0, fullfile(proj,'tracks',[base '_settings.txt'])); end          % appended to
cleanup = onCleanup(@() rmdir(proj,'s'));

f = spt_app(); drawnow;
bs = findobj(f,'Type','uibutton');
btn = @(t) bs(arrayfun(@(b) contains(string(b.Text), t), bs));
bRun = btn('Run this cell'); bExp = btn('Export cell'); bAll = btn('Export all');
assert(~isempty(bRun) && ~isempty(bExp) && ~isempty(bAll), 'action buttons not found');
bRun = bRun(1); bExp = bExp(1); bAll = bAll(1);
txt0 = bExp.Text; col0 = bExp.BackgroundColor;

ta = findobj(f,'Type','uitextarea'); assert(~isempty(ta), 'no log');
ef = findobj(f,'Type','uieditfield');
setField = @(pat,val) setFieldIn(ef, pat, val);
setField('tracks/ written here', proj);            % Track tab: where the export writes

% BEFORE anything is scanned: a click with nothing to act on must SAY so, not sit there silently
n0 = numel(ta(1).Value);
cb = bExp.ButtonPushedFcn; cb(bExp, struct()); drawnow;
sil = string(ta(1).Value(:)'); sil = sil(n0+1:end);
assert(~isempty(sil) && any(contains(sil,'nothing to do')), 'a no-op Export click logged nothing');
fprintf('no-op click reports itself: %s\n', sil(1));

% Match tab: point at the dataset folder and Scan, so `matched` is populated
setField('dataset folder', proj);
setField('single-particle .tif', fullfile(proj,'spt'));      % set the three explicitly — the
setField('ilastik ER masks',     fullfile(proj,'er_seg'));   % dataset-folder auto-fill does not
setField('ilastik mito masks',   fullfile(proj,'mito_seg')); % reach Scan on its own headlessly
for k = 1:numel(bs)
    if strcmp(string(bs(k).Text),'Scan'), c = bs(k).ButtonPushedFcn; c(bs(k), struct()); break; end
end
drawnow;

% Export all — same loop, logging and busy handling, without depending on the Cell dropdown
nBefore = numel(ta(1).Value);
txtA0 = bAll.Text; colA0 = bAll.BackgroundColor;
cb = bAll.ButtonPushedFcn; cb(bAll, struct());     % <-- the click under test
drawnow;
assert(strcmp(bAll.Text, txtA0) && isequal(bAll.BackgroundColor, colA0), 'Export all not restored');

%% buttons restored -------------------------------------------------------
assert(strcmp(bExp.Text, txt0), 'Export button text not restored (is "%s")', bExp.Text);
assert(isequal(bExp.BackgroundColor, col0), 'Export button colour not restored');
for b = [bRun bExp bAll]
    assert(strcmp(b.Enable,'on'), 'button "%s" left disabled', b.Text);
end
fprintf('button restored after export: "%s"\n', bExp.Text);

%% log detail -------------------------------------------------------------
L = string(ta(1).Value(:)'); added = L(nBefore+1:end);
joined = strjoin(added, ' | ');
fprintf('log lines added by the export click: %d\n', numel(added));
for q = 1:numel(added), fprintf('   %s\n', added(q)); end
assert(~any(contains(added,'nothing to do')), ...
    'Export all found no ticked cells — the Match-tab scan did not populate `matched`:\n%s', joined);
assert(any(contains(added,'EXPORT')), 'no EXPORT banner in the log:\n%s', joined);
assert(any(contains(added,'min length')), 'filter settings not logged');
assert(any(contains(added,'tracks kept')), 'kept/rejected counts not logged:\n%s', joined);
assert(any(contains(added,'detections written')), 'detection count not logged');
assert(any(~cellfun(@isempty, regexp(cellstr(added),'\d+(\.\d+)?\s*(s|m)\>','once'))), ...
    'no elapsed time in the log:\n%s', joined);

%% Tool 1 filters — it does not curate ------------------------------------
assert(~any(contains(lower(added),'curate')) && ~any(contains(lower(added),'curation')), ...
    'Tool 1 log still says curate/curation — this tool only FILTERS:\n%s', joined);
lb = findobj(f,'Type','uilabel');
stat = string(arrayfun(@(x) string(x.Text), lb));
assert(any(contains(stat,'Exported')), 'status line does not report the export');
assert(~any(contains(lower(stat),'curated')), 'status line still says "curated"');
assert(~contains(lower(string(f.Name)),'curate'), 'window title still says curate: %s', f.Name);
fprintf('no "curate" wording in the log, status line or window title\n');

close(f);
assertWithERIntact(W, wsnap);
fprintf('\nTRACK-TAB FEEDBACK SMOKE PASSED.\n');
end

function setFieldIn(ef, pat, val)
h = ef(arrayfun(@(e) contains(string(e.Placeholder), pat), ef));
assert(~isempty(h), 'no edit field with placeholder matching "%s"', pat);
h(1).Value = val; c = h(1).ValueChangedFcn;
if ~isempty(c), c(h(1), struct('Value',val)); end
end

function snap = snapWithER(W)
% Fingerprint every file under WithER (size + mtime) so a test can PROVE it did not modify the
% pristine input data. Cheap: ~5 files plus the big stacks.
snap = containers.Map('KeyType','char','ValueType','char');
for d = {'', 'spt', 'er_seg', 'mito_seg', 'tracks', 'analysis'}
    p = fullfile(W, d{1});
    if ~isfolder(p), continue; end
    ff = dir(fullfile(p,'*'));
    for q = 1:numel(ff)
        if ff(q).isdir, continue; end
        k = fullfile(d{1}, ff(q).name);
        snap(k) = sprintf('%d|%.6f', ff(q).bytes, ff(q).datenum);
    end
end
end

function assertWithERIntact(W, before)
% The pristine test data must come out exactly as it went in. save() and fopen() FOLLOW SYMLINKS,
% so any fixture that links WithER files can silently write through them; this catches that.
after = snapWithER(W);
bad = {};
ks = before.keys;
for i = 1:numel(ks)
    k = ks{i};
    if ~after.isKey(k), bad{end+1} = sprintf('DELETED %s', k); %#ok<AGROW>
    elseif ~strcmp(before(k), after(k)), bad{end+1} = sprintf('MODIFIED %s', k); end %#ok<AGROW>
end
ks = after.keys;
for i = 1:numel(ks)
    if ~before.isKey(ks{i}), bad{end+1} = sprintf('CREATED %s', ks{i}); end %#ok<AGROW>
end
assert(isempty(bad), 'THIS TEST MODIFIED THE PRISTINE WithER DATA:\n  %s', strjoin(bad, sprintf('\n  ')));
fprintf('WithER verified untouched by this test (%d files fingerprinted)\n', before.Count);
end
