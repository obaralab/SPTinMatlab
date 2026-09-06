function c = spt_project_calib(projectDir, base, useManifest)
%SPT_PROJECT_CALIB  The calibration a project actually has, most-trustworthy source first.
%
%   c = spt_project_calib(projectDir)              % from the first cell that can supply one
%   c = spt_project_calib(projectDir, base)        % from that specific cell
%   c = spt_project_calib(projectDir, base, false) % ignore the manifest (see EDITED, below)
%
% OUTPUT (NaN where nothing could supply it — never a guess):
%   .pixUm .dt_s .fovUm    and .src, one label per field:
%                          'edited'   YOU typed it in the Experiment tab — outranks everything ·
%                          'settings' Tool 1's _settings.txt · 'movie' the TIFF metadata ·
%                          'xml' the tracks XML · 'derived' computed (FOV = (width-1)*pixel)
%                          · 'missing' nothing could supply it
%   .width .height         image dimensions in PIXELS, and .src.dims ('movie'|'missing'). These are
%                          what the FOV is computed from — a 256 x 256 stack at 0.107 um/px is a
%                          27.3 um field — so a wrong FOV is almost always a wrong pixel size
%                          against a right width, and showing the dimensions makes that visible
%                          instead of leaving one unexplained number on a toolbar.
%   .base                  the cell it came from
%   .why                   one line for a status bar, naming the source
%
% WHY THIS EXISTS
% Tool 1 records what it actually tracked with — tracks/<base>_settings.txt carries
% calibration.pixel_um and calibration.frame_s — and Tool 2 read none of it. Its Auto button read
% only frameInterval out of a tracks XML, so the pixel size and field of view stayed at whatever the
% panel happened to hold, which for a new dataset is the previous dataset's numbers.
%
% Worse, Tool 2 then WROTE those stale defaults into the project as cs_calib.mat, on open, before the
% user had touched anything — so opening a correctly-tracked project replaced its calibration with
% the wrong one, and the next read believed it.
%
% Resolution order, and why:
%   0. YOUR EDIT, from the experiment manifest (<project>/experiment_details.mat). When nothing in
%      the files can supply a calibration the tools fall back to whatever the panel holds, and the
%      Experiment tab is where you correct that. A correction that the resolver then ignores is
%      worse than no correction at all: the number changes on the Experiment tab, every other tool
%      goes on using the fallback, and the two disagree with nothing on screen to say so. So a
%      hand-edited value is read back here FIRST and wins outright — including over Tool 1's own
%      _settings.txt, because a person who has typed a pixel size is asserting that the tracking
%      record is the thing that is wrong. Only values the panel marked LOCKED (pixLock/dtLock, set
%      exclusively by a hand edit) are taken; a value the panel merely reported back is not.
%   1. tracks/<base>_settings.txt — what Tool 1 ACTUALLY USED to produce the µm coordinates in the
%      XML. Nothing else can contradict it without making the coordinates wrong.
%   2. the movie TIFF's own metadata (spt_tiff_calib) — the instrument's answer, and the only source
%      for the image DIMENSIONS, and so for the field of view, which Tool 1 does not record.
%   3. the tracks XML frameInterval — dt only.
% The panel is deliberately NOT in this list: it is the fallback the CALLER applies when this returns
% nothing, not a source of truth to be preferred over a measurement. An EDIT is a different thing
% from the panel's resting value — it is a deliberate assertion about this dataset, recorded per
% cell — which is why rank 0 exists and the panel still has no rank at all.
%
% useManifest=false is for cs_experiment_scan, which FILLS the manifest: it must report what the
% filesystem currently says, and the panel then re-applies the user's edit on top of the rescan. If
% the scan read the manifest instead, an edit would become its own evidence and no rescan could ever
% show what the files actually contain.
%
% Localization precision and the density bin are absent on purpose. Neither is recoverable from
% anything Tool 1 writes — precision is a property of the fit and the bin is an analysis choice — so
% they stay the user's to set, and a function that guessed at them would be inventing data.

c = struct('pixUm',NaN,'dt_s',NaN,'fovUm',NaN,'width',NaN,'height',NaN,'base','', ...
           'src',struct('pixUm','missing','dt_s','missing','fovUm','missing','dims','missing'), ...
           'why','');
if nargin < 1 || isempty(projectDir) || ~isfolder(projectDir), return; end
if nargin < 2, base = ''; end
if nargin < 3 || isempty(useManifest), useManifest = true; end

tr = fullfile(projectDir,'tracks'); if ~isfolder(tr), tr = projectDir; end

% The manifest's hand-edited rows for THIS project, most-edited-first. Read before the base is
% chosen because an edit can also ANSWER the question "which cell?": on a project the resolver would
% otherwise call unreadable, the cell the user corrected is the one that can supply a calibration.
ed = [];
if useManifest, ed = manifestEdits(projectDir); end

% Which cell? The named one, else the first the user corrected, else the first that has a settings
% file, else the first XML.
bases = {};
if ~isempty(base)
    bases = {char(base)};
else
    if ~isempty(ed), bases{end+1} = ed(1).file; end
    L = dir(fullfile(tr,'*_settings.txt'));
    for k = 1:numel(L), bases{end+1} = regexprep(L(k).name,'_settings\.txt$',''); end %#ok<AGROW>
    if isempty(bases)
        L = dir(fullfile(tr,'*_tracks*.xml'));
        for k = 1:numel(L), bases{end+1} = regexprep(L(k).name,'_tracks(_filtered|_curated)?\.xml$',''); end %#ok<AGROW>
    end
end
if isempty(bases), c.why = 'no tracked cells in this project'; return; end
c.base = bases{1};

% ---- 0. YOUR EDIT — outranks every file on disk --------------------------------------------------
% Taken only when the panel marked the value LOCKED, which only a hand edit does. Everything below
% is written to check isfinite() first, so an edited field is never overwritten by a measured one;
% an edited pixel size with no edited dt still lets dt resolve normally from the files.
if useManifest
    e = pickEdit(ed, c.base);
    if ~isempty(e)
        if e.pixLock && inr(e.pixUm,0.005,5),  c.pixUm = e.pixUm; c.src.pixUm = 'edited'; end
        if e.dtLock  && inr(e.dtS,1e-6,3600),  c.dt_s  = e.dtS;   c.src.dt_s  = 'edited'; end
    end
end

% ---- 1. Tool 1's own record ---------------------------------------------------------------------
f = fullfile(tr,[c.base '_settings.txt']);
if isfile(f)
    try
        txt = fileread(f);
        % isfinite() first: an EDITED value is already in place and must not be overwritten by the
        % file it corrects. Ranks 2 and 3 below were always written this way; this one was not, and
        % without the guard a settings file silently reinstated the number the user had just fixed.
        if ~isfinite(c.pixUm)
            v = key(txt,'calibration.pixel_um');
            if inr(v,0.005,5),   c.pixUm = v; c.src.pixUm = 'settings'; end
        end
        if ~isfinite(c.dt_s)
            v = key(txt,'calibration.frame_s');
            if inr(v,1e-6,3600), c.dt_s = v;  c.src.dt_s  = 'settings'; end
        end
    catch
    end
end

% ---- 2. the movie itself — and the only source for the image dimensions --------------------------
mov = findMovie(projectDir, c.base);
if ~isempty(mov)
    if exist('spt_tiff_calib','file')==2
        try
            m = spt_tiff_calib(mov);
            if ~isfinite(c.pixUm) && inr(m.pixUm,0.005,5), c.pixUm = m.pixUm; c.src.pixUm = 'movie'; end
            if ~isfinite(c.dt_s)  && inr(m.dt_s,1e-6,3600), c.dt_s  = m.dt_s;  c.src.dt_s  = 'movie';  end
            % The DIMENSIONS are taken whatever the pixel size turned out to be. They used to be read
            % only inside the "pixel size came from the movie" branch, so a project whose pixel size
            % came from _settings.txt — the common case — reported no width at all and therefore no
            % FOV, leaving the panel's stale FOV in place with nothing on screen to say it was stale.
            if isfinite(m.width) && m.width > 1 && isfinite(m.height) && m.height > 0
                c.width = m.width; c.height = m.height; c.src.dims = 'movie';
            end
        catch
        end
    end
end

% ---- FOV — always DERIVED from the dimensions and the pixel size that won -------------------------
% FOV spans the CENTRES of the first and last columns, matching X_um = (0-based col)*pixUm. It is
% never read from anywhere: it is a consequence of two numbers above it, so an edited pixel size
% recomputes it and the three can never disagree on screen.
if isfinite(c.pixUm) && isfinite(c.width)
    c.fovUm = (c.width-1)*c.pixUm; c.src.fovUm = 'derived';
end

% ---- 3. the tracks XML, for dt only ---------------------------------------------------------------
if ~isfinite(c.dt_s)
    L = dir(fullfile(tr,[c.base '_tracks*.xml']));
    if ~isempty(L)
        try
            head = fileread(fullfile(L(1).folder,L(1).name));
            t = regexp(head,'frameInterval="([\d.eE+-]+)"','tokens','once');
            if ~isempty(t)
                v = str2double(t{1});
                if inr(v,1e-6,3600), c.dt_s = v; c.src.dt_s = 'xml'; end
            end
        catch
        end
    end
end

got = {};
if isfinite(c.pixUm), got{end+1} = sprintf('%.5g µm/px (%s)', c.pixUm, c.src.pixUm); end
if isfinite(c.dt_s),  got{end+1} = sprintf('%.5g s/frame (%s)', c.dt_s, c.src.dt_s); end
if isfinite(c.fovUm)
    if isfinite(c.width) && isfinite(c.height)
        got{end+1} = sprintf('%.5g µm FOV (%gx%g px x %.5g µm)', c.fovUm, c.width, c.height, c.pixUm);
    else
        got{end+1} = sprintf('%.5g µm FOV (%s)', c.fovUm, c.src.fovUm);
    end
elseif isfinite(c.width)
    got{end+1} = sprintf('%gx%g px (no pixel size, so no FOV)', c.width, c.height);
end
if isempty(got), c.why = sprintf('%s: nothing readable — using the panel values', c.base);
else,            c.why = sprintf('%s: %s', c.base, strjoin(got,' · ')); end
end

% =================================================================================================
function ed = manifestEdits(projectDir)
%MANIFESTEDITS  The hand-edited calibration rows of <project>/experiment_details.mat, for THIS
%project. Returns an empty struct array when there is no manifest, no matching rows, or no edits.
%
% Matching is on the project path, canonicalised, and accepts the analysis/ subfolder either way
% round: Tool 1 adds <project> to the manifest and Tools 2 and 3 add <project>/analysis, and both
% mean the same project. Getting that wrong is silent — the edit is found for one tool and not the
% other, which is the exact failure this whole path exists to fix — so it is handled here once
% rather than at each call site.
ed = struct('file',{},'pixUm',{},'pixLock',{},'dtS',{},'dtLock',{});
mf = fullfile(projectDir,'experiment_details.mat');
if ~isfile(mf), return; end
try, S = load(mf,'manifest'); catch, return; end
if ~isfield(S,'manifest') || ~isstruct(S.manifest) || ~isfield(S.manifest,'cells'), return; end
cl = S.manifest.cells;
if isempty(cl) || ~isstruct(cl), return; end

want = canon(projectDir);
alt  = {want, canon(fullfile(projectDir,'analysis')), canon(fileparts(projectDir))};

for k = 1:numel(cl)
    r = cl(k);
    if ~isfield(r,'file') || isempty(r.file), continue; end
    pj = ''; if isfield(r,'project'), pj = canon(r.project); end
    if ~isempty(pj) && ~any(strcmp(pj, alt)), continue; end
    pl = isfield(r,'pixLock') && ~isempty(r.pixLock) && r.pixLock;
    dl = isfield(r,'dtLock')  && ~isempty(r.dtLock)  && r.dtLock;
    if ~pl && ~dl, continue; end                    % a REPORTED value is not an edit
    ed(end+1) = struct('file',char(r.file), ...
        'pixUm', num(r,'pixUm'), 'pixLock', pl, ...
        'dtS',   num(r,'dtS'),   'dtLock', dl); %#ok<AGROW>
end
end

function e = pickEdit(ed, base)
% The edit for this cell. Falls back to the FIRST edited row only when there is exactly one distinct
% edited calibration in the project — if two cells were corrected to different numbers there is no
% "the project's" calibration to borrow, and inventing one would put a number on the toolbar that
% belongs to a different cell.
e = [];
if isempty(ed), return; end
hit = strcmp({ed.file}, char(base));
if any(hit), e = ed(find(hit,1)); return; end
if isscalar(ed), e = ed(1); return; end
same = arrayfun(@(x) isequaln(x.pixUm,ed(1).pixUm) && isequaln(x.dtS,ed(1).dtS) && ...
                     x.pixLock==ed(1).pixLock && x.dtLock==ed(1).dtLock, ed);
if all(same), e = ed(1); end
end

function v = num(r, f)
v = NaN;
if isfield(r,f) && isscalar(r.(f)) && isnumeric(r.(f)), v = double(r.(f)); end
end

function p = canon(d)
p = '';
if isempty(d), return; end
p = char(d);
try, q = char(java.io.File(p).getCanonicalPath()); if ~isempty(q), p = q; end, catch, end
end

% =================================================================================================
function p = findMovie(projectDir, base)
% The raw stack for this cell. <project>/spt/<base>.tif is the pipeline's layout; the others are
% there so a flatter folder still resolves.
p = '';
for d = {fullfile(projectDir,'spt'), projectDir, fullfile(projectDir,'raw'), fullfile(projectDir,'images')}
    if ~isfolder(d{1}), continue; end
    for e = {'.tif','.tiff','.ome.tif'}
        f = fullfile(d{1}, [base e{1}]);
        if isfile(f), p = f; return; end
    end
end
end

function v = key(txt, k)
v = NaN;
t = regexp(txt, ['(?m)^\s*' regexptranslate('escape',k) '\s*=\s*(-?[\d.]+(?:[eE][-+]?\d+)?)'], 'tokens','once');
if ~isempty(t), v = str2double(t{1}); end
end

function tf = inr(v, lo, hi)
tf = isscalar(v) && isnumeric(v) && isfinite(v) && v >= lo && v <= hi;
end
