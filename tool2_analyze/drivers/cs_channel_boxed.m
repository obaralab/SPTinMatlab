function [v, found] = cs_channel_boxed(s, container, key)
%CS_CHANNEL_BOXED  Fetch s.(container).(key) — the keyed storage — without ever throwing.
%
%   [v, found] = cs_channel_boxed(s, container, key)
%
% The one place the keyed lookup is spelled out, so every accessor agrees on what counts as "the
% keyed form is present". It is deliberately strict about the container:
%
%   - a MISSING container means the record predates the migration;
%   - a container that is [] rather than a struct means combine_trackstructs filled in a field one
%     source had and another did not (it deals [] into every gap), which is the same thing;
%   - a container that HAS the container but not this key means this channel was not imaged for this
%     cell, while another was — a partially-keyed record, which must fall through to the flat name
%     rather than read as missing.
%
% All three return found=false, and every caller then tries the legacy flat field. `found` is true
% even when v is empty, so a caller can tell "keyed, and genuinely has no data" from "not keyed".
v = []; found = false;
if ~isstruct(s) || ~isscalar(s) || ~isfield(s, container), return; end
c = s.(container);
if ~isstruct(c) || ~isscalar(c) || ~isfield(c, key), return; end
v = c.(key); found = true;
end
