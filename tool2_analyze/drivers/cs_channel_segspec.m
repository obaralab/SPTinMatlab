function spec = cs_channel_segspec(chans, projectDir)
%CS_CHANNEL_SEGSPEC  Turn a channel config into the plain (key, dir, suffix) spec spt_match takes.
%
%   spec = cs_channel_segspec(chans, projectDir)
%
% The bridge between the config and file discovery. It is deliberately PLAIN DATA — key, folder
% path, suffix regex — because spt_match and spt_channel_token live in tool1_track and must not
% depend on tool2_analyze/drivers. Tool 2 builds the spec and passes it down; Tool 1 keeps working
% from its own defaults with no knowledge of the config at all.
%
% INPUT
%   chans      : struct array from cs_channel_config; [] or omitted for the built-in default.
%   projectDir : project root, prepended to each channel's folder. '' leaves folders relative.
%
% OUTPUT
%   spec : 1xN struct('key',..,'dir',..,'suffix',..) in declaration order.
if nargin < 1 || isempty(chans), chans = cs_channel_config(); end
if nargin < 2, projectDir = ''; end
projectDir = char(projectDir);

spec = struct('key',{},'dir',{},'suffix',{});
for i = 1:numel(chans)
    F = cs_channel_fields(chans(i));
    d = F.folder;
    if ~isempty(projectDir), d = fullfile(projectDir, F.folder); end
    spec(end+1) = struct('key',F.key,'dir',d,'suffix',F.suffix); %#ok<AGROW>
end
end
