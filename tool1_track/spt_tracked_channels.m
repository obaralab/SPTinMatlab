function out = spt_tracked_channels(mode, projectDir, C)
%SPT_TRACKED_CHANNELS  The TRACKED colours of a project: which pages each one is, and its own dt.
%
%   C = spt_tracked_channels('load', projectDir)
%   C = spt_tracked_channels('default')
%       spt_tracked_channels('save', projectDir, C)
%   p = spt_tracked_channels('path', projectDir)
%
% A reference channel (ER, mito) is a MASK, declared in channels.json and read page for page. A
% tracked channel is a second thing entirely: its own particles, tracked on their own, with their
% own frame rate. This is that list.
%
% ONE ENTRY PER COLOUR:
%   key      lower-case identifier, ^[a-z][a-z0-9_]*$, unique. It is the token in the output names
%            (spt_channel_stem), so it must survive a file name.
%   label    human-readable, for the UI.
%   stride   page step in the stack. 1 = every page. 2 = one colour of an interleaved pair.
%   offset   0-based page offset of this colour's first page. Interleaved colours differ here.
%   dt_s     THIS COLOUR'S frame interval, in seconds. NaN = derive it as (page interval x stride),
%            which is right for a plain interleaved pair and wrong the moment a colour is strobed
%            or the two colours come from separate stacks with their own timing.
%   file     '' = this colour lives in the cell's own SPT stack (the interleaved case). A pattern
%            or suffix here names a separate stack instead.
%
% WHY dt IS PER CHANNEL AND NOT DERIVED. Deriving it assumes the only reason a colour has fewer
% frames is that it shares pages with another colour. A strobed colour — every other exposure, in
% its own stack — has stride 1 and a dt that is nothing to do with the page interval. Getting this
% wrong scales every diffusion coefficient, dwell time and rate by exactly that factor, silently,
% because seconds are what those are reported in.
%
% THE DEFAULT IS ONE CHANNEL WITH NO KEY, which composes to the bare file names this pipeline has
% always written. A project with no tracked_channels.json behaves exactly as it did.

if nargin < 1 || isempty(mode), mode = 'default'; end
mode = lower(char(mode));
switch mode
    case 'default'
        out = defaultC();
    case 'path'
        out = cfgPath(projectDir);
    case 'load'
        out = defaultC();
        p = cfgPath(projectDir);
        if isempty(p) || ~isfile(p), return; end
        try
            raw = jsondecode(fileread(p));
        catch ME
            warning('spt_tracked_channels:badJson', ...
                'tracked_channels.json could not be read (%s) — using the single-channel default.', ME.message);
            return;
        end
        if isstruct(raw) && isfield(raw,'tracked'), raw = raw.tracked; end
        if isempty(raw), return; end
        if iscell(raw), raw = [raw{:}]; end
        C2 = defaultC(); C2(:) = [];
        for i = 1:numel(raw)
            e = normalise(raw(i));
            if isempty(e.key), continue; end
            if any(strcmp({C2.key}, e.key))
                warning('spt_tracked_channels:dupKey', 'duplicate tracked channel key ''%s'' ignored', e.key);
                continue;
            end
            C2(end+1) = e; %#ok<AGROW>
        end
        if ~isempty(C2), out = C2; end
    case 'save'
        p = cfgPath(projectDir);
        assert(~isempty(p), 'spt_tracked_channels:noProject', 'no project folder to save into');
        s = struct('tracked', {arrayfun(@(e) normalise(e), C(:)', 'uni', 0)});
        fid = fopen(p, 'w');
        assert(fid > 0, 'spt_tracked_channels:noWrite', 'could not write %s', p);
        fprintf(fid, '%s\n', jsonencode(s, 'PrettyPrint', true));
        fclose(fid);
        out = p;
    otherwise
        error('spt_tracked_channels:mode', 'unknown mode ''%s''', mode);
end
end

% =================================================================================================
function C = defaultC()
% One colour, no key: the names this pipeline has always written.
C = struct('key','', 'label','(single)', 'stride',1, 'offset',0, 'dt_s',NaN, 'file','');
end

function e = normalise(r)
e = defaultC();
if ~isstruct(r), return; end
e.key    = lower(strtrim(char(getf(r,'key',''))));
e.label  = char(getf(r,'label', e.key));
e.stride = max(1, round(double(getf(r,'stride',1))));
e.offset = max(0, round(double(getf(r,'offset',0))));
e.file   = char(getf(r,'file',''));
d = double(getf(r,'dt_s',NaN));
if isempty(d) || ~isfinite(d) || d <= 0, d = NaN; end
e.dt_s = d;
if ~isempty(e.key) && isempty(regexp(e.key, '^[a-z][a-z0-9_]*$', 'once'))
    warning('spt_tracked_channels:badKey', ...
        'tracked channel key ''%s'' is not [a-z][a-z0-9_]* and was dropped', e.key);
    e.key = '';
end
if isempty(e.label), e.label = e.key; end
end

function p = cfgPath(projectDir)
p = '';
if nargin < 1 || isempty(projectDir), return; end
d = char(projectDir);
[~, leaf] = fileparts(d);
if strcmpi(leaf, 'analysis'), d = fileparts(d); end   % tolerate being handed analysis/
p = fullfile(d, 'tracked_channels.json');
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
