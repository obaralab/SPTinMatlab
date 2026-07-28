function base = cellBase(fileField, cfg)
%CELLBASE  Per-cell image "base" name derived from Tracks(i).file.
%
% Replaces the scattered idiom file(1:end-7), which assumed every cell name
% ended in a 7-character tag. The number of trailing tag characters is now a
% single documented setting, cs_config.m -> FileTagChars:
%
%   FileTagChars = 0  -> base = file            (integrated pipeline default)
%   FileTagChars = 7  -> base = file(1:end-7)   (original Nature-paper runs)
%
%   base = cellBase(Tracks(i).file)         % uses cs_config()
%   base = cellBase(Tracks(i).file, cfg)    % pass a cfg you already loaded
%
% Errors if the name is shorter than the tag it is asked to strip.

if nargin < 2 || isempty(cfg), cfg = cs_config(); end
f = char(fileField);
k = cfg.FileTagChars;
if k == 0
    base = f;
elseif numel(f) > k
    base = f(1:end-k);
else
    error('cellBase:tooShort', ...
      ['Tracks.file = "%s" is shorter than FileTagChars=%d. Set ' ...
       'cs_config.FileTagChars to match your naming convention.'], f, k);
end
end
