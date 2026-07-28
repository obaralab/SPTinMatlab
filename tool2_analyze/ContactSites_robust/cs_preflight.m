function ok = cs_preflight(analysisDir, varargin)
%CS_PREFLIGHT  Validate a ContactSites run folder BEFORE the suite runs.
%
% Scans analysisDir and prints a pass/fail table so naming/layout problems
% surface as clear messages up front — instead of as cryptic index or
% "file not found" errors deep inside the suite. Checks:
%
%   * TrackStruct.mat / Tracks.mat present and loadable
%   * every Tracks(i).file resolves to a cell base (cellBase)
%   * required subfolders exist (canonical case)
%   * per-cell images present under the expected names (MaxInt, Mito, Density)
%   * case-clash detection (e.g. CSdata vs CSData on case-insensitive disks)
%
%   ok = cs_preflight(analysisDir)
%   ok = cs_preflight(analysisDir, 'Stage','mapper')   % check inputs for one stage
%
% Returns true if no BLOCKING problem was found. Warnings (yellow) do not
% block; failures (red) do.

ip = inputParser;
ip.addParameter('Stage','all',@ischar);
ip.parse(varargin{:});
stage = ip.Results.Stage;
cfg = cs_config();

fprintf('\n=== ContactSites preflight: %s ===\n', analysisDir);
nFail = 0; nWarn = 0;
    function report(level,label,msg)
        switch level
            case 'ok',   fprintf('  [ OK ] %-22s %s\n',label,msg);
            case 'warn', fprintf('  [WARN] %-22s %s\n',label,msg); 
            case 'fail', fprintf('  [FAIL] %-22s %s\n',label,msg);
        end
    end

% ---- 1. Track struct -------------------------------------------------------
mat = '';
for c = {'TrackStruct.mat','Tracks.mat'}
    if isfile(fullfile(analysisDir,c{1})), mat = c{1}; break; end
end
if isempty(mat)
    report('fail','TrackStruct.mat','not found — run build_trackstruct first');
    nFail = nFail+1; Tracks = [];
else
    Sload = load(fullfile(analysisDir,mat));
    if ~isfield(Sload,'Tracks')
        report('fail',mat,'has no variable ''Tracks'''); nFail=nFail+1; Tracks=[];
    else
        Tracks = Sload.Tracks;
        report('ok',mat,sprintf('%d cell(s)',numel(Tracks)));
    end
end

% ---- 2. cell bases ---------------------------------------------------------
bases = {};
if ~isempty(Tracks)
    try
        bases = arrayfun(@(t) cellBase(t.file,cfg), Tracks, 'uni',0);
        report('ok','cell bases',strjoin(bases,', '));
    catch ME
        report('fail','cell bases',ME.message); nFail=nFail+1;
    end
end

% ---- 3. required folders (+ case-clash) -----------------------------------
need = {cfg.dir.Densities, cfg.dir.csIDs, cfg.dir.TrackData, cfg.dir.CSdata};
existing = dir(analysisDir); existing = {existing([existing.isdir]).name};
for d = need
    hit = existing(strcmpi(existing,d{1}));   % case-insensitive match
    if isempty(hit)
        report('warn',['dir ' d{1}],'missing (created by a later stage, or setup_run_folder)');
        nWarn = nWarn+1;
    elseif ~any(strcmp(hit,d{1}))
        report('fail',['dir ' d{1}], ...
            sprintf('case mismatch: found "%s", expected "%s"',hit{1},d{1}));
        nFail = nFail+1;
    else
        report('ok',['dir ' d{1}],'present');
    end
end
% explicit CSdata/CSData clash note
if any(strcmp(existing,'CSdata')) && any(strcmp(existing,'CSData'))
    report('fail','CSdata/CSData','BOTH exist — data is split across two folders');
    nFail = nFail+1;
end

% ---- 4. per-cell images ----------------------------------------------------
if ~isempty(bases)
    checkImg(bases, cfg.dir.MaxInt, cfg.suffix.MaxIntRGB, stage, {'quickplot','all'});
    checkImg(bases, cfg.dir.Mito,   cfg.suffix.MitoV2,    stage, {'builder','all'});
    checkImg(bases, cfg.dir.Densities, cfg.suffix.Density, stage, {'mapper','all'});
end

    function checkImg(bases, sub, suf, stage, stagesNeeding)
        if ~ismember(stage,stagesNeeding), return; end
        miss = {};
        for b = bases(:)'
            if ~isfile(fullfile(analysisDir,sub,[b{1} suf])), miss{end+1}=b{1}; end %#ok
        end
        lbl = [sub '/*' suf];
        if isempty(miss), report('ok',lbl,'all present');
        else, report('warn',lbl,sprintf('missing for: %s',strjoin(miss,', '))); nWarn=nWarn+1; end
    end

% ---- verdict ---------------------------------------------------------------
fprintf('  ------------------------------------------\n');
fprintf('  %d fail, %d warn\n', nFail, nWarn);
ok = (nFail==0);
if ok, fprintf('  READY.\n\n'); else, fprintf('  NOT READY — resolve [FAIL] items above.\n\n'); end
end
