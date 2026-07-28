function base = stripSuffix(name, suffix)
%STRIPSUFFIX  Remove a KNOWN literal suffix from a filename, robustly.
%
% Replaces the fragile idiom name(1:end-N), which strips a FIXED character
% count and silently corrupts the base if the name length ever changes.
% stripSuffix removes the actual suffix string and errors loudly if it is
% not present — so a naming mismatch fails at the source with a clear message
% instead of surfacing as a "file not found" deep in the suite.
%
%   base = stripSuffix('cellA_CSdata.mat', '_CSdata.mat')   % -> 'cellA'
%   base = stripSuffix('cellA_CSdata.mat', 'CSdata.mat')    % -> 'cellA_'
%
% name/suffix may be char or string; base is returned as char.

name   = char(name);
suffix = char(suffix);
n = numel(suffix);
if numel(name) >= n && strcmp(name(end-n+1:end), suffix)
    base = name(1:end-n);
else
    error('stripSuffix:noMatch', ...
      ['Expected "%s" to end with "%s".\n' ...
       'A file is not named the way this stage expects — check the run ' ...
       'folder / naming convention (cs_config.m) rather than editing the ' ...
       'character count.'], name, suffix);
end
end
