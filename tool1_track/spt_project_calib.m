function c = spt_project_calib(projectDir, base)
%SPT_PROJECT_CALIB  The calibration a project actually has, most-trustworthy source first.
%
%   c = spt_project_calib(projectDir)         % from the first cell that can supply one
%   c = spt_project_calib(projectDir, base)   % from that specific cell
%
% OUTPUT (NaN where nothing could supply it — never a guess):
%   .pixUm .dt_s .fovUm    and .src, one label per field:
%                          'settings' Tool 1's _settings.txt · 'movie' the TIFF metadata ·
%                          'xml' the tracks XML · 'derived' computed (FOV = (width-1)*pixel)
%                          · 'missing' nothing could supply it
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
%   1. tracks/<base>_settings.txt — what Tool 1 ACTUALLY USED to produce the µm coordinates in the
%      XML. Nothing else can contradict it without making the coordinates wrong.
%   2. the movie TIFF's own metadata (spt_tiff_calib) — the instrument's answer, and the only source
%      for the field of view, which Tool 1 does not record.
%   3. the tracks XML frameInterval — dt only.
% The panel is deliberately NOT in this list: it is the fallback the CALLER applies when this returns
% nothing, not a source of truth to be preferred over a measurement.
%
% Localization precision and the density bin are absent on purpose. Neither is recoverable from
% anything Tool 1 writes — precision is a property of the fit and the bin is an analysis choice — so
% they stay the user's to set, and a function that guessed at them would be inventing data.

c = struct('pixUm',NaN,'dt_s',NaN,'fovUm',NaN,'base','', ...
           'src',struct('pixUm','missing','dt_s','missing','fovUm','missing'),'why','');
if nargin < 1 || isempty(projectDir) || ~isfolder(projectDir), return; end
if nargin < 2, base = ''; end

tr = fullfile(projectDir,'tracks'); if ~isfolder(tr), tr = projectDir; end

% Which cell? The named one, else the first that has a settings file, else the first XML.
bases = {};
if ~isempty(base)
    bases = {char(base)};
else
    L = dir(fullfile(tr,'*_settings.txt'));
    for k = 1:numel(L), bases{end+1} = regexprep(L(k).name,'_settings\.txt$',''); end %#ok<AGROW>
    if isempty(bases)
        L = dir(fullfile(tr,'*_tracks*.xml'));
        for k = 1:numel(L), bases{end+1} = regexprep(L(k).name,'_tracks(_filtered|_curated)?\.xml$',''); end %#ok<AGROW>
    end
end
if isempty(bases), c.why = 'no tracked cells in this project'; return; end
c.base = bases{1};

% ---- 1. Tool 1's own record ---------------------------------------------------------------------
f = fullfile(tr,[c.base '_settings.txt']);
if isfile(f)
    try
        txt = fileread(f);
        v = key(txt,'calibration.pixel_um');
        if inr(v,0.005,5),   c.pixUm = v; c.src.pixUm = 'settings'; end
        v = key(txt,'calibration.frame_s');
        if inr(v,1e-6,3600), c.dt_s = v;  c.src.dt_s  = 'settings'; end
    catch
    end
end

% ---- 2. the movie itself — and the only source for the field of view -----------------------------
mov = findMovie(projectDir, c.base);
if ~isempty(mov) && exist('spt_tiff_calib','file')==2
    try
        m = spt_tiff_calib(mov);
        if ~isfinite(c.pixUm) && inr(m.pixUm,0.005,5), c.pixUm = m.pixUm; c.src.pixUm = 'movie'; end
        if ~isfinite(c.dt_s)  && inr(m.dt_s,1e-6,3600), c.dt_s  = m.dt_s;  c.src.dt_s  = 'movie';  end
        % FOV spans the CENTRES of the first and last columns, matching X_um = (0-based col)*pixUm.
        if isfinite(c.pixUm)
            try
                info = imfinfo(mov);
                W = double(info(1).Width);
                if W > 1, c.fovUm = (W-1)*c.pixUm; c.src.fovUm = 'derived'; end
            catch
            end
        end
    catch
    end
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
if isfinite(c.fovUm), got{end+1} = sprintf('%.5g µm FOV (%s)', c.fovUm, c.src.fovUm); end
if isempty(got), c.why = sprintf('%s: nothing readable — using the panel values', c.base);
else,            c.why = sprintf('%s: %s', c.base, strjoin(got,' · ')); end
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
