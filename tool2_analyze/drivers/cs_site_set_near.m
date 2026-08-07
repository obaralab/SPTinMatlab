function cs = cs_site_set_near(cs, key, tf)
%CS_SITE_SET_NEAR  Write the per-site proximity flag. The flag is a BOOLEAN — always, everywhere.
%
%   cs = cs_site_set_near(cs, key, tf)      key: 'mito'; tf: anything scalar and finite
%
% This is the only writer. It stores a 1x1 LOGICAL, which is what the flag has always meant and now
% is: "does this contact site touch the named organelle". Before this, the same field was written as
% a logical by the mapper and the pipeline app and as a DOUBLE by the refiner, so a single
% CS_final.mat could hold both classes depending on which tool last touched each site, and every one
% of the ~20 readers had to wrap the value in logical(), ==1, or a bare if.
%
% Reading is separate and stays permissive: cs_site_near still accepts the legacy double, NaN and []
% forms, so .mat files written before this change keep loading unchanged. Only what this pipeline
% WRITES from now on is normalised.
%
% Writes BOTH forms: the keyed cs.near.<key> that readers prefer, and the flat legacy field that
% everything written before the migration still uses. Nothing has to be converted, and a CS_final.mat
% produced now still opens in a build from before this change. Step 4 drops the flat write.
%
% Spelling of the flat field follows the record: 'MitoFlag' on CS/CSW records, 'mito' on footprint
% and dwell records (cs_channel_fields.siteAny). A record that has neither gets the canonical name,
% so field order at the call site is preserved exactly as a bare assignment would leave it — the
% keyed container is appended after, since it is new to the record either way.
%
% Errors on a non-scalar or non-finite value rather than coercing it. A writer that quietly turns
% NaN into false hides the bug that produced the NaN; a reader that does the same only survives one.
F = cs_channel_fields(key);
if isempty(F.site)
    error('cs_site_set_near:noSiteFlag', ...
        'Channel ''%s'' is a %s channel and has no per-site flag.', F.key, F.role);
end
if ~isstruct(cs), error('cs_site_set_near:notAStruct', 'cs must be a scalar struct.'); end
if ~isscalar(tf) || ~(islogical(tf) || isnumeric(tf)) || (isnumeric(tf) && ~isfinite(tf))
    error('cs_site_set_near:badValue', ...
        'The %s flag must be a finite scalar; got a %s of size %s.', ...
        F.site, class(tf), mat2str(size(tf)));
end
tf = logical(tf);
box = struct();                                  % keyed storage — what readers prefer. Rebuilt
if isfield(cs, F.box.site) && isstruct(cs.(F.box.site)) && isscalar(cs.(F.box.site))
    box = cs.(F.box.site);                       % rather than assigned into, because the container
end                                              % can arrive as [] from combine_trackstructs
box.(F.key) = tf;
cs.(F.box.site) = box;
fld = F.site;                                    % canonical unless the record already spells it
for i = 1:numel(F.siteAny)                       % the other way
    if isfield(cs, F.siteAny{i}), fld = F.siteAny{i}; break; end
end
cs.(fld) = tf;                                   % flat legacy field, kept in step-2 dual-write
end
