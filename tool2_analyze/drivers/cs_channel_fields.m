function f = cs_channel_fields(key)
%CS_CHANNEL_FIELDS  Storage names for one reference channel — the ONE place organelle names live.
%
%   f = cs_channel_fields(key)   key: 'er' | 'mito' | any configured key, or a channel record
%                                     returned by cs_channel_config
%
% The pipeline used to hard-code two organelles in five layers (folder names, filename suffixes,
% per-cell path fields, per-spot distance arrays, per-site flags). Every one of those spellings is
% listed HERE and nowhere else.
%
% Two ROLES, deliberately not interchangeable:
%   'support'   restricts where detection happens and supplies the background denominator. At most
%               ONE per project. Absent means detection derives its support from the localizations
%               themselves — see cs_support_mask — NOT the whole frame, which would take the
%               background median over mostly-empty field and inflate enrichment without bound.
%   'proximity' contributes a signed per-spot distance and a per-site flag. Zero or many; absent
%               means the column is simply not there.
%
% OUTPUT  f : struct with fields
%   key     canonical lower-case key. This is the field name inside the keyed containers, so it is
%           also what makes a third channel need no new name here at all.
%   role    'support' | 'proximity'
%   label   human-readable name for UI text
%   seg     per-cell record field holding the segmentation path ('erSeg' / 'mitoSeg', or '<key>Seg')
%   folder  project sub-folder holding the segmentation stacks
%   suffix  regex stripped from the end of a file stem so a segmentation keys against the cell name
%   mip     whole-movie projection filename pattern, {prefix} standing for the cell base
%   box     the KEYED containers, channel-independent and the same for every channel:
%             box.mat   'dist'  -> Tracks(k).dist.<key>          [nFrames x nTracks] signed um
%             box.spots 'DIST'  -> Tracks(k).allSpots.DIST.<key> [nDetections x 1]  signed um
%             box.site  'near'  -> record.near.<key>             scalar logical
%   mat/spots/site/siteAny
%           the FLAT legacy names, and '' / {} for any channel that never had them. Only 'er' and
%           'mito' predate the keyed storage, so only they carry these. Readers prefer the keyed
%           form and fall back to these; a channel with none is simply keyed-only, which is what
%           every new channel is and what step 4 makes universal.
%
% An unknown but well-formed key is NOT an error: it is a channel this build has no legacy names
% for, which is exactly what a configured third channel is. cs_channel_config validates the declared
% keys, so a typo is caught where the names are declared rather than where they are read.
BOX = struct('mat','dist','spots','DIST','site','near');

if isstruct(key)                                     % a record from cs_channel_config
    c = key;
    if ~isfield(c,'key'), error('cs_channel_fields:badRecord','channel record has no key.'); end
    k = lower(strtrim(char(c.key)));
    f = base_(k, getf_(c,'role','proximity'), getf_(c,'label',''), ...
        getf_(c,'folder',''), getf_(c,'suffix',''), getf_(c,'mip',''), BOX);
    return
end

k = lower(strtrim(char(key)));
if isempty(regexp(k, '^[a-z][a-z0-9_]*$', 'once'))
    error('cs_channel_fields:badKey', ...
        ['''%s'' is not a usable channel key. The key becomes a struct field name in the keyed ' ...
         'storage, so it must start with a letter and hold only a-z, 0-9 and _.'], k);
end
d = defaults_(k);
f = base_(k, d.role, d.label, d.folder, d.suffix, d.mip, BOX);
end

% ------------------------------------------------------------------------------------------------
function f = base_(k, role, label, folder, suffix, mip, BOX)
if isempty(label), label = k; label(1) = upper(label(1)); end
if isempty(folder), folder = [k '_seg']; end
if isempty(suffix), suffix = ['_' k]; end
if isempty(mip),    mip    = ['{prefix}_' k '_mip.tif']; end
f = struct('key',k,'role',lower(strtrim(char(role))),'label',label, ...
    'seg',[k 'Seg'],'folder',folder,'suffix',suffix,'mip',mip,'box',BOX, ...
    'mat','','spots','','site','','siteAny',{{}});
% The flat legacy names, for the two channels that predate the keyed storage. The site flag is
% spelled 'MitoFlag' on CS/CSW records and 'mito' on footprint and dwell records; no record carries
% both, so a reader may accept either while a writer picks the canonical one.
switch k
    case 'er'
        f.mat = 'erDist';   f.spots = 'ERDIST';   f.seg = 'erSeg';
    case 'mito'
        f.mat = 'mitoDist'; f.spots = 'MITODIST'; f.seg = 'mitoSeg';
        f.site = 'MitoFlag'; f.siteAny = {'MitoFlag','mito'};
end
end

function d = defaults_(k)
% Built-in conventions for the two channels this pipeline shipped with. Anything else gets the
% generic pattern in base_, which is what cs_channel_config also hands a newly declared channel.
switch k
    case 'er'
        d = struct('role','support','label','ER','folder','er_seg', ...
            'suffix','_(2_TA_BC|er_mip|er)','mip','{prefix}_er_mip.tif');
    case 'mito'
        d = struct('role','proximity','label','Mito','folder','mito_seg', ...
            'suffix','_(3_TA_BC|mito_mip|ch1_mito|mito)','mip','{prefix}_mito_mip.tif');
    otherwise
        d = struct('role','proximity','label','','folder','','suffix','','mip','');
end
end

function v = getf_(s, f, d)
v = d; if isfield(s,f) && ~isempty(s.(f)), v = char(string(s.(f))); end
end
