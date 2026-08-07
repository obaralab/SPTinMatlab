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
%   box     the KEYED containers that replace the flat names above, channel-independent:
%             box.mat   'dist'  -> Tracks(k).dist.<key>          [nFrames x nTracks] signed um
%             box.spots 'DIST'  -> Tracks(k).allSpots.DIST.<key> [nDetections x 1]  signed um
%             box.site  'near'  -> record.near.<key>             scalar logical
%           Inside a container the field name IS the channel key, so a third channel needs no new
%           name here at all — which is the whole point of moving the storage.
%
% MIGRATION (step 2). Producers write BOTH forms; readers prefer the keyed one and fall back to the
% flat one, so a TrackStruct.mat built before this still loads with nothing to convert. An ABSENT
% key inside a present container means "not imaged" and falls through to the flat name too — a
% partially-keyed struct (dist.mito but no dist.er) must not read ER as missing. combine_trackstructs
% fills a field one source lacks with [], so `dist` may also be a plain [] rather than a struct;
% every reader treats that as "no keyed storage".
%
% A field that is '' means the channel genuinely has no such storage — callers must treat that as
% "absent", not as an error. Unknown keys ERROR: until the channel config of step 3 exists, a typo
% would otherwise be indistinguishable from a channel that was never imaged.
BOX = struct('mat','dist','spots','DIST','site','near');   % same containers for every channel
key = lower(strtrim(char(key)));
switch key
    case 'er'
        f = struct('key','er','role','support','label','ER', ...
            'mat','erDist','spots','ERDIST','site','','siteAny',{{}},'seg','erSeg','folder','er_seg', ...
            'box',BOX);
    case 'mito'
        f = struct('key','mito','role','proximity','label','Mito', ...
            'mat','mitoDist','spots','MITODIST','site','MitoFlag','siteAny',{{'MitoFlag','mito'}}, ...
            'seg','mitoSeg','folder','mito_seg','box',BOX);
    otherwise
        error('cs_channel_fields:unknownKey', ...
            'Unknown channel key ''%s''. Known keys: %s.', key, strjoin(cs_channel_keys(), ', '));
end
end
