function spt_qc_table_smoke()
%SPT_QC_TABLE_SMOKE  The Build & QC cell table must not claim a channel it has no data for, and its
%inherited-value marker must not read as a unit.
%
% WHAT IS ASSERTED:
%   1. PRESENT-BUT-EMPTY IS ITS OWN STATE. cs_channel_has answers "is the array there?", and the
%      importer decides that from the CSV COLUMN NAME alone — so a cell with an ER_DIST_UM column
%      and no ER segmentation carries a full-NaN matrix. A plain ✓ claimed ER on a cell whose own
%      status line said "(no ER)", because that line tests for FINITE values. The table now
%      distinguishes ✓ (data), NaN (column present, nothing in it) and – (no column).
%   2. THE TABLE AND THE STATUS LINE AGREE. They are two readouts of the same question and were
%      answering it differently, which is worse than either answer alone.
%   3. THE INHERITED MARKER IS NOT A UNIT. It is '*', not '°': in a column headed "FOV µm" a degree
%      sign reads as degrees, and every calibration column carries a real unit in its header.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_qctbl_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'analysis'));
cleanup = onCleanup(@() rmdir(proj,'s'));

% One cell with real mito distances and an ER matrix that is present but ENTIRELY NaN — the shape a
% project gets when the spots CSV has an ER_DIST_UM column and no ER segmentation behind it.
nF = 40; nT = 6;
rng(2);
X = 5 + cumsum(0.02*randn(nF,nT)); Y = 5 + cumsum(0.02*randn(nF,nT));
T = struct();
T.matrix = cat(3, repmat((1:nF)',1,nT), X, Y);
T.frameInterval = 0.02; T.file = 'cellA';
T.lengths = repmat(nF, nT, 1); T.trackIDs = (1:nT)';
T.MSD = rand(nF-1, nT); T.Dt = rand(nF, nT); T.CSD = cumsum(rand(nF-1, nT));
T.dist = struct('mito', abs(X-5), 'er', nan(nF,nT));     % ER present, all NaN
Tracks = T; %#ok<NASGU>
save(fullfile(proj,'analysis','TrackStruct.mat'),'Tracks','-v7.3');
fid = fopen(fullfile(proj,'analysis','active_trackstruct.txt'),'w');
fprintf(fid,'TrackStruct.mat\n'); fclose(fid);

f = spt_analyze_app('analysis'); f.Visible = 'off';
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;
press(f,'Load TrackStruct');

tb = pick(findobj(f,'Type','uitable'), @(x) any(strcmp(x.ColumnName,'med len')), 'build cell table');
hdr = cellstr(string(tb.ColumnName(:)'));
D = tb.Data;
assert(~isempty(D), 'the cell table is empty');

%% (1) present-but-empty is reported as such --------------------------------------------------------
iER = find(strcmpi(hdr,'ER'), 1);
assert(~isempty(iER), 'the table has no ER column: %s', strjoin(hdr,', '));
erMark = char(string(D{1,iER}));
assert(~strcmp(erMark,'✓'), ...
    ['the ER column shows a tick on a cell whose ER distances are ALL NaN. The column exists ' ...
     'because the spots CSV had the header, not because anything was segmented — a tick here ' ...
     'contradicts the cell''s own status line.']);
assert(strcmp(erMark,'NaN'), 'the ER column shows "%s"; wanted NaN for present-but-empty', erMark);

iMi = find(strcmpi(hdr,'Mito'), 1);
if ~isempty(iMi)
    assert(strcmp(char(string(D{1,iMi})),'✓'), ...
        'the Mito column shows "%s" on a cell that HAS finite mito distances', char(string(D{1,iMi})));
end

%% (2) the table and the QC status line agree --------------------------------------------------------
lb = findobj(f,'Type','uilabel');
st = '';
for k = 1:numel(lb)
    t = char(string(lb(k).Text));
    if contains(t,'click a track to inspect'), st = t; break; end
end
assert(~isempty(st), 'the QC status line was not found');
assert(contains(st,'no ER'), ...
    'the status line says "%s" — it should report no ER, which is what the table must agree with', st);

%% (3) the inherited marker is not a unit -------------------------------------------------------------
row = cellfun(@(x) char(string(x)), D(1,:), 'uni', 0);
joined = strjoin(row, ' ');
assert(~contains(joined, '°'), ...
    ['a calibration cell still carries "°": %s. Every one of those columns has a real unit in its ' ...
     'header, so a degree sign there reads as degrees rather than as "inherited".'], joined);
iFov = find(strcmpi(hdr,'FOV µm'), 1);
assert(~isempty(iFov), 'no FOV column: %s', strjoin(hdr,', '));
fovTxt = char(string(D{1,iFov}));
assert(~isempty(regexp(fovTxt,'^[\d.eE+-]+\*?$','once')), ...
    'the FOV cell reads "%s"; it should be a number, optionally followed by the * inherited marker', fovTxt);

fprintf('ER present-but-empty -> "%s" · mito -> "%s" · FOV -> "%s"\n', erMark, ...
    char(string(D{1,iMi})), fovTxt);
fprintf('\nQC-TABLE SMOKE PASSED.\n');
end

% ================================================================================================
function press(h, txt)
b = findobj(h,'Type','uibutton');
q = b(arrayfun(@(x) contains(string(x.Text), txt), b));
assert(~isempty(q), 'button "%s" not found', txt);
cb = q(1).ButtonPushedFcn; cb(q(1), struct()); drawnow;
end

function h = pick(hs, test, what)
hit = hs(arrayfun(@(x) safe(test,x), hs));
assert(~isempty(hit), 'could not find the %s', what);
h = hit(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
