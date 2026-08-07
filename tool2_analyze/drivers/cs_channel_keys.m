function keys = cs_channel_keys(role)
%CS_CHANNEL_KEYS  The reference channels this build knows about, optionally filtered by role.
%
%   keys = cs_channel_keys()             {'er','mito'}
%   keys = cs_channel_keys('support')    {'er'}
%   keys = cs_channel_keys('proximity')  {'mito'}
%
% Loop over THIS rather than writing ER and mito out by hand, so code written today keeps working
% when the list becomes project-configurable. Always a cellstr, possibly empty.
keys = {'er','mito'};
if nargin >= 1 && ~isempty(role)
    role = strtrim(char(role));
    keep = false(1, numel(keys));
    for i = 1:numel(keys), keep(i) = strcmpi(cs_channel_fields(keys{i}).role, role); end
    keys = keys(keep);
end
end
