function f = cs_channel_fields(key)
%CS_CHANNEL_FIELDS  Storage names for one reference channel — the ONE place organelle names live.
%
%   f = cs_channel_fields(key)      key: 'er' | 'mito' (case-insensitive)
%
% The pipeline hard-codes two organelles in five different layers (folder names, filename suffixes,
% per-cell path fields, per-spot distance arrays, per-site flags). Every one of those spellings is
% listed HERE and nowhere else, so a later step can swap the storage — a keyed struct, a channel
% config file — by rewriting this function alone instead of ~200 call sites.
%
% Two ROLES, deliberately not interchangeable:
%   'support'   restricts where detection happens and supplies the background denominator. At most
%               ONE per project; absent means "whole field" (cs_detect already falls back to that).
%   'proximity' contributes a signed per-spot distance and a per-site flag. Zero or many; absent
%               means the column is simply not there.
%
% OUTPUT  f : struct with fields
%   key     canonical lower-case key ('er' / 'mito')
%   role    'support' | 'proximity'
%   label   human-readable name for UI text ('ER' / 'Mito')
%   mat     Tracks(k) field holding the [nFrames x nTracks] signed distance ('erDist' / 'mitoDist')
%   spots   Tracks(k).allSpots field holding the per-detection signed distance ('ERDIST' / 'MITODIST')
%   site    canonical per-site proximity flag ('MitoFlag'); '' when the channel has none
%   siteAny every spelling of that flag a record may legitimately carry, most-canonical first. The
%           SAME boolean is stored under THREE names today — 'MitoFlag' on CS/CSW records
%           (cs_window_mapper), and 'mito' on the derived footprint records (cs_footprints_build)
%           and on dwell events / per-site rows (cs_window_dwell). No record carries two of them, so
%           a reader can accept any; a writer must pick one, which is why 'site' stays singular.
%   seg     per-cell record field holding the segmentation path ('erSeg' / 'mitoSeg')
%   folder  project sub-folder holding the segmentation stacks ('er_seg' / 'mito_seg')
%
% A field that is '' means the channel genuinely has no such storage — callers must treat that as
% "absent", not as an error. Unknown keys ERROR: until the channel config of step 3 exists, a typo
% would otherwise be indistinguishable from a channel that was never imaged.
key = lower(strtrim(char(key)));
switch key
    case 'er'
        f = struct('key','er','role','support','label','ER', ...
            'mat','erDist','spots','ERDIST','site','','siteAny',{{}},'seg','erSeg','folder','er_seg');
    case 'mito'
        f = struct('key','mito','role','proximity','label','Mito', ...
            'mat','mitoDist','spots','MITODIST','site','MitoFlag','siteAny',{{'MitoFlag','mito'}}, ...
            'seg','mitoSeg','folder','mito_seg');
    otherwise
        error('cs_channel_fields:unknownKey', ...
            'Unknown channel key ''%s''. Known keys: %s.', key, strjoin(cs_channel_keys(), ', '));
end
end
