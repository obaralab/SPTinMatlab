function [chans, info] = cs_channel_config(projectDir)
%CS_CHANNEL_CONFIG  The reference channels THIS project has, from its own channels.json.
%
%   [chans, info] = cs_channel_config(projectDir)
%
% A project declares its own channels instead of the pipeline assuming ER and mito. With no
% channels.json — which is every dataset that exists today — this returns the built-in default, so
% nothing has to be created for an existing project to keep working exactly as it did.
%
% INPUT
%   projectDir : project root (the folder holding spt/, the seg folders, tracks/, analysis/). May
%                also be the analysis/ sub-folder, or '' for the built-in default with no file read.
%
% OUTPUT
%   chans : 1xN struct array, one per reference channel, in declaration order:
%     key     lower-case identifier, unique, matching ^[a-z][a-z0-9_]*$. This is the field name used
%             inside the keyed storage (Tracks(k).dist.<key>), so it must be a valid MATLAB field.
%     role    'support' | 'proximity'  (see cs_channel_fields for what each means)
%     label   human-readable, for UI text
%     folder  sub-folder of the project holding this channel's segmentation stacks
%     suffix  regex matched at the END of a file stem to strip this channel's own naming, so a
%             segmentation keys against the cell name the SPT stack uses
%     mip     filename pattern for the whole-movie projection, with {prefix} for the cell base;
%             '' when this channel has none
%   info : .source   'default' | full path of the channels.json that was read
%          .warnings cellstr — anything ignored or defaulted, so a caller can surface it
%
% AT MOST ONE SUPPORT CHANNEL. A support channel restricts detection and supplies the background
% denominator, and two of those would be two different answers to the same question. Declaring a
% second one is an error, not a warning.
%
% ZERO support channels is legal and is the point of the exercise. Detection then derives its support
% from the localizations themselves (see cs_support_mask) rather than falling back to the whole
% frame, which would take the background median over mostly-empty field and inflate enrichment
% without bound.
info = struct('source','default','warnings',{{}});
chans = builtin_default();
if nargin < 1 || isempty(projectDir), return; end

p = char(projectDir);
f = fullfile(p, 'channels.json');
if ~isfile(f)
    f2 = fullfile(fileparts(p), 'channels.json');    % tolerate being handed analysis/
    if isfile(f2), f = f2; else, return; end
end

try
    raw = jsondecode(fileread(f));
catch ME
    error('cs_channel_config:badJson', '%s is not readable JSON: %s', f, ME.message);
end
if isstruct(raw) && isfield(raw,'channels'), raw = raw.channels; end
if isempty(raw)
    info.warnings{end+1} = sprintf('%s declares no channels; using the built-in default.', f);
    return
end
if isstruct(raw), raw = num2cell(raw(:)'); end       % jsondecode gives a struct array when uniform
if ~iscell(raw), raw = {raw}; end

DEF = builtin_default();
out = emptyChans();
for i = 1:numel(raw)
    c = raw{i};
    if ~isstruct(c) || ~isfield(c,'key')
        error('cs_channel_config:noKey', '%s: channel %d has no "key".', f, i);
    end
    key = lower(strtrim(char(c.key)));
    if isempty(regexp(key, '^[a-z][a-z0-9_]*$', 'once'))
        error('cs_channel_config:badKey', ...
            ['%s: channel key ''%s'' is not usable. The key becomes a struct field name in the ' ...
             'keyed storage, so it must start with a letter and hold only a-z, 0-9 and _.'], f, key);
    end
    if any(strcmp({out.key}, key))
        error('cs_channel_config:duplicateKey', '%s: channel key ''%s'' is declared twice.', f, key);
    end
    d = defaultFor(DEF, key);                        % a redeclared er/mito inherits our conventions
    e = struct('key',key, ...
        'role',   pick(c,'role',   d.role), ...
        'label',  pick(c,'label',  d.label), ...
        'folder', pick(c,'folder', d.folder), ...
        'suffix', pick(c,'suffix', d.suffix), ...
        'mip',    pick(c,'mip',    d.mip));
    e.role = lower(strtrim(e.role));
    if ~any(strcmp(e.role, {'support','proximity'}))
        error('cs_channel_config:badRole', ...
            '%s: channel ''%s'' has role ''%s''; it must be ''support'' or ''proximity''.', f, key, e.role);
    end
    if isempty(e.folder)
        info.warnings{end+1} = sprintf('channel ''%s'' declares no folder; it will never resolve a file.', key);
    end
    out(end+1) = e; %#ok<AGROW>
end

nSup = sum(strcmp({out.role}, 'support'));
if nSup > 1
    error('cs_channel_config:twoSupports', ...
        ['%s declares %d support channels (%s). A support channel is the detection domain AND the ' ...
         'background denominator, so there can be at most one.'], ...
        f, nSup, strjoin({out(strcmp({out.role},'support')).key}, ', '));
end
if nSup == 0
    info.warnings{end+1} = ['no support channel declared — detection will derive its support from ' ...
        'the localizations themselves (cs_support_mask), which is reported per run.'];
end

chans = out; info.source = f;
end

% ------------------------------------------------------------------------------------------------
function c = builtin_default()
% Today's conventions, exactly. Every dataset in this pipeline predates the config, so this is what
% they all get. The suffix regexes are the ones spt_match has always used.
c = emptyChans();
c(end+1) = struct('key','er','role','support','label','ER','folder','er_seg', ...
    'suffix','_(2_TA_BC|er_mip|er)','mip','{prefix}_er_mip.tif');
c(end+1) = struct('key','mito','role','proximity','label','Mito','folder','mito_seg', ...
    'suffix','_(3_TA_BC|mito_mip|ch1_mito|mito)','mip','{prefix}_mito_mip.tif');
end

function d = defaultFor(DEF, key)
% A config that names 'er' or 'mito' without spelling out the folder/suffix inherits the built-in
% ones, so declaring "this project has ER only" is a two-line file rather than a transcription.
i = find(strcmp({DEF.key}, key), 1);
if ~isempty(i), d = DEF(i); return; end
lab = key; lab(1) = upper(lab(1));                   % 'lyso' -> 'Lyso', a usable UI label
d = struct('key',key,'role','proximity','label',lab, ...
    'folder',[key '_seg'],'suffix',['_' key],'mip',['{prefix}_' key '_mip.tif']);
end

function v = pick(c, f, d)
v = d;
if isfield(c, f) && ~isempty(c.(f)), v = char(string(c.(f))); end
end

function c = emptyChans()
c = struct('key',{},'role',{},'label',{},'folder',{},'suffix',{},'mip',{});
end
