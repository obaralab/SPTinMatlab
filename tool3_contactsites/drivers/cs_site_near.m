function tf = cs_site_near(cs, key)
%CS_SITE_NEAR  Is this contact site flagged as touching the named reference channel?
%
%   tf = cs_site_near(cs, key)      cs: ONE CS record; key: 'mito' (the only flagged channel today)
%
% Scalar logical, always. The flag is stored as MitoFlag and is variously a double 0/1 (as written
% by the mapper and by cs_refine) or a logical (as flipped in the pipeline app), so every read site
% wrapped it in logical() by hand — with three different levels of guarding. This is the one guarded
% read: missing field, empty value, or a channel with no per-site flag at all all give FALSE rather
% than an error, which is what the guarded call sites already did and what the bare ones assumed.
%
% No producer stores a non-scalar flag, but if one ever appears this reads it as all-non-zero — the
% `if c` semantics of the eight bare tern(logical(...)) sites — rather than the scalar-only `&&` of
% the two guarded ones, which errors.
tf = false;
F = cs_channel_fields(key);
if ~strcmp(F.role,'proximity'), return; end      % a SUPPORT channel has no per-site flag at all
if ~isstruct(cs), return; end
[v, keyed] = cs_channel_boxed(cs, F.box.site, F.key);   % cs.near.<key> — the keyed form wins
if ~keyed
    fld = '';                                    % the same flag is spelled 'MitoFlag' on CS/CSW
    for i = 1:numel(F.siteAny)                   % records and 'mito' on footprint / dwell records.
        if isfield(cs, F.siteAny{i}), fld = F.siteAny{i}; break; end
    end                                          % A channel newer than the keyed storage has no
    if isempty(fld), return; end                 % flat spelling at all — keyed or nothing.
    v = cs.(fld);
end
if isempty(v), return; end                       % legacy CSdata templates ship MitoFlag = []
if ~isnumeric(v) && ~islogical(v), return; end
if isnumeric(v) && ~all(isfinite(v(:))), return; end   % NaN would throw in logical(); absent = false
tf = all(v(:) ~= 0);
end
