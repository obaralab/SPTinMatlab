function keys = cs_channel_keys(a, b)
%CS_CHANNEL_KEYS  The reference-channel keys in play, optionally filtered by role.
%
%   keys = cs_channel_keys()             {'er','mito'} — the built-in default
%   keys = cs_channel_keys('support')    {'er'}
%   keys = cs_channel_keys(chans)        the keys a project declared (cs_channel_config)
%   keys = cs_channel_keys(chans,'support')
%
% Loop over THIS rather than writing channel names out by hand: code written against it keeps
% working when a project declares one channel, three, or a set that includes neither ER nor mito.
% Always a cellstr, possibly empty — a project with no support channel returns {} for that role,
% and callers must handle it (that is the case cs_support_mask exists for).
chans = []; role = '';
if nargin >= 1
    if isstruct(a), chans = a; elseif ~isempty(a), role = char(a); end
end
if nargin >= 2 && ~isempty(b), role = char(b); end

if isempty(chans)
    keys = {'er','mito'};                            % built-in default, no project consulted
    roles = cellfun(@(k) cs_channel_fields(k).role, keys, 'UniformOutput', false);
else
    keys  = arrayfun(@(c) lower(strtrim(char(c.key))), chans(:)', 'UniformOutput', false);
    roles = arrayfun(@(c) lower(strtrim(char(c.role))), chans(:)', 'UniformOutput', false);
end

if ~isempty(role)
    keep = strcmpi(roles, strtrim(role));
    keys = keys(keep);
end
keys = reshape(keys, 1, []);
end
