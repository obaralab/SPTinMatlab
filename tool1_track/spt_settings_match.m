function [re, tok, src] = spt_settings_match(tracksDir)
%SPT_SETTINGS_MATCH  The file-matching regex Tool 1 actually used, read back from its settings files.
%
%   [re, tok, src] = spt_settings_match(tracksDir)
%
% Tool 1 pairs each SPT movie with its segmentations by stripping a channel token from the names —
% either one it derived from the files or one the user typed because the naming is unusual. Tools 2
% and 3 have to redo that pairing to resolve overlays, and before this was recorded they could only
% RE-DERIVE it (spt_channel_token), which works when a segmentation name is a prefix of the SPT name
% and fails silently otherwise. The typed case was simply unrecoverable.
%
% spt_write_settings now records it per cell as
%     matching.strip_regex    = ...
%     matching.channel_token  = ...
% and this reads it back.
%
% INPUT
%   tracksDir : a Tool 1 tracks/ folder (or a project root — its tracks/ is tried).
%
% OUTPUT
%   re  : the regex to hand to spt_match. '' means "match with nothing stripped", which is a real
%         answer, so use `src` to tell it apart from "nothing was recorded".
%   tok : the human-readable token ('_C3'), for status lines.
%   src : full path of the settings file it came from; '' when nothing was recorded. ALWAYS test
%         this rather than isempty(re).
%
% The token is a property of the PROJECT's naming, not of one cell, so the first settings file that
% carries the key wins. A folder written by a Tool 1 older than this returns src = '' and the caller
% falls back to deriving, exactly as before.
re = ''; tok = ''; src = '';
if nargin < 1 || isempty(tracksDir), return; end
d = char(tracksDir);
if ~isfolder(d), return; end
if isempty(dir(fullfile(d,'*_settings.txt'))) && isfolder(fullfile(d,'tracks'))
    d = fullfile(d,'tracks');                    % tolerate being handed the project root
end

L = dir(fullfile(d, '*_settings.txt'));
for k = 1:numel(L)
    p = fullfile(L(k).folder, L(k).name);
    try, txt = fileread(p); catch, continue; end
    r = grab(txt, 'matching.strip_regex');
    t = grab(txt, 'matching.channel_token');
    if isempty(r) && isempty(t), continue; end   % older Tool 1: key absent entirely
    if strcmp(r,'(none)'), r = ''; end           % recorded, and the answer was "strip nothing"
    if strcmp(t,'(none)'), t = ''; end
    re = r; tok = t; src = p; return
end
end

% ------------------------------------------------------------------------------------------------
function v = grab(txt, key)
% Value of `key = ...` up to end of line, trimmed. Returns '' when the key is absent — which is why
% the caller distinguishes "absent" from "present but empty" using src, not this.
v = '';
m = regexp(txt, [regexptranslate('escape',key) '\s*=\s*([^\r\n]*)'], 'tokens', 'once');
if ~isempty(m), v = strtrim(m{1}); end
end
