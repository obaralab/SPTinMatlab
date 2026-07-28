function state = run_contactsite_analysis(workDir, varargin)
% RUN_CONTACTSITE_ANALYSIS  Staged, resumable driver for the ContactSites
% (Nature-paper) suite. Translates InstructionsAfterTracking.txt into an
% ordered set of MATLAB stages with precondition checks. The former Fiji and
% Wacom gates are now in-MATLAB interactive stages (cs_identify, cs_refine)
% that block for mouse input and then continue in-flow — no software round-trip.
%
% The suite is a mix of MATLAB functions and bare scripts that depend on the
% current folder + workspace variables. This driver:
%   * enforces the correct order and the folder/variable hand-offs,
%   * checks that each stage's inputs exist before running it,
%   * runs every MATLAB stage for you (the two interactive picking/refining
%     stages open a window, block for your clicks, then continue automatically),
%   * is resumable: pass 'StartStage' to pick up at any stage.
%
% USAGE
%   run_contactsite_analysis(workDir)                       % from the top
%   run_contactsite_analysis(workDir,'StartStage','mapper') % resume
%   run_contactsite_analysis(workDir,'JBM',false,'MitoOnly',true)
%
% workDir must contain to START:
%   TrackStruct.mat  (or Tracks.mat) — from build_trackstruct.m (var 'Tracks')
%   MaxInt/          — RGB files '*_3_MaxInt_RGB.tif'
% Optional (JBM branch): ER/  Mito/  Maps/  Densities/
%
% NAME-VALUE
%   'StartStage' : first stage to run (default 'density'). One of the STAGES
%                  keys below. Use to resume at any stage.
%   'StopAfter'  : last stage to run (default '' = run to the end).
%   'JBM'        : true (default) use ContactSiteMapper + Deff branch;
%                  false -> ContactSiteMapperNoDeff + skip Deff-only stages.
%   'MitoOnly'   : true -> cs_refine(MitoFlag 1) + CSensemble1 (mito-flag CSs
%                  only); false (default) -> refine all CSs + CSensemble2.
%   'PixSize'    : density pixel size passed to DensityVisualization /
%                  LocDensityFigIntUse (default 30).
%   'SuitePath'  : path to the ContactSites suite root to addpath (recommended).
%
% RETURNS  state : struct logging which stage it stopped at and why.
%
% ---------------------------------------------------------------------------
% This function does not modify any suite .m file. It calls them exactly as
% the instructions intend, in the intended working directory.

ip = inputParser;
ip.addParameter('StartStage','density',@ischar);
ip.addParameter('StopAfter','',@ischar);
ip.addParameter('JBM',true,@islogical);
ip.addParameter('MitoOnly',false,@islogical);
ip.addParameter('OnlyCS',[],@isnumeric);   % refiner stage: re-refine only these csIDs (keep the rest)
ip.addParameter('OnlyCell',[],@isnumeric); % ...in this cell only (csID is per-cell)
ip.addParameter('ProgressFcn',[]);         % called @(k,nStages,key,typ,desc) at each stage start (live UI)
ip.addParameter('PixSize',30,@isnumeric);
ip.addParameter('SuitePath','',@ischar);
ip.addParameter('UIParent',[]);   % uipanel/uitab to embed cs_identify + cs_refine (from the app); [] = own windows
ip.addParameter('MitoDir','',@ischar);                     % mito folder for the picker/refiner auto-overlay
ip.addParameter('MitoPat','{prefix}_mito_mip.tif',@ischar);
ip.addParameter('MitoStrip','_spt\d+',@ischar);
ip.addParameter('ErDir','',@ischar);                       % ER folder for the refiner overlay
ip.addParameter('ErPat','{prefix}_er_mip.tif',@ischar);
ip.addParameter('IncludeFiles',{},@iscell);               % session cell selection: only these are pickable ({}=all)
ip.addParameter('TrackStructFile','',@ischar);            % which TrackStruct .mat to run on ('' = TrackStruct.mat)
ip.parse(varargin{:});
o = ip.Results;

assert(isfolder(workDir),'workDir not found: %s',workDir);
if ~isempty(o.SuitePath) && isfolder(o.SuitePath)
    addpath(genpath(o.SuitePath));
end
addpath(fileparts(mfilename('fullpath')));   % ensure sibling drivers (cs_identify, …) resolve
% Cleaner console: show warnings as one-liners (no giant call-stack backtrace).
wbt = warning('off','backtrace'); restoreWarn = onCleanup(@() warning(wbt)); %#ok<NASGU>

% Ordered stage list. All stages run in-MATLAB; 'csid' and 'refiner' are 'auto'
% but interactive (they open a window and block for mouse input, then continue).
STAGES = {
 'density'   'auto'  'DensityVisualization(Tracks,PixSize,true) + move *_rho.tif -> Densities/'
 'locdens'   'auto'  'for i: LocDensityFigIntUse(Tracks,i,PixSize)'
 'quickplot' 'auto'  'QuickPlotterTracks (QC track plots)'
 'csid'      'auto'  'cs_identify: in-MATLAB interactive CS picking -> csIDs/*_CSsites.txt'
 'mapper'    'auto'  'ContactSiteMapper[NoDeff]: build TrackData/ + CSdata/'
 'part2'     'auto'  'Part2: CStabulator+CellAccumulator -> CSindexing.mat, Tracks_final.mat(+MitoCSindex)'
 'snaprename' 'auto' 'rename CSdata/ -> CSsnaps/, make fresh CSdata/'
 'refiner'   'auto'  'cs_refine: in-MATLAB mouse CS centre/boundary refine -> CSdata/*_CSdata.mat'
 'ensemble'  'auto'  'CSensemble1|2: net ensemble Deff for Prism/Excel (JBM only)'
 'builder'   'auto'  'CS_builder(Tracks) -> CS_final.mat'
 'accum'     'auto'  'ConditionAccumulatorFinal: Excel table + per-CS reference images'
};
keys = STAGES(:,1);

i0 = find(strcmpi(keys,o.StartStage),1);
assert(~isempty(i0),'Unknown StartStage "%s". Valid: %s',o.StartStage,strjoin(keys,', '));
iEnd = numel(keys);
if ~isempty(o.StopAfter)
    j = find(strcmpi(keys,o.StopAfter),1);
    assert(~isempty(j),'Unknown StopAfter "%s".',o.StopAfter);
    iEnd = j;
end

state = struct('stopped_at','','reason','','next','','workDir',workDir);
old = cd(workDir); cleaner = onCleanup(@() cd(old));   % always restore cwd

% --- reconcile the chosen TrackStruct .mat -> the suite's Tracks.mat --------
% A named build (e.g. Day1.mat, a subselection) is a valid input: if the user picked one,
% (re)derive Tracks.mat from it — that also lets them switch which build a run uses.
tsSel = '';
if ~isempty(o.TrackStructFile) && isfile(o.TrackStructFile), tsSel = o.TrackStructFile; end
if ~isempty(tsSel)
    S = load(tsSel);
    assert(isfield(S,'Tracks'), '%s has no variable ''Tracks''.', tsSel);
    Tracks = S.Tracks;                          %#ok<NASGU>
    save('Tracks.mat','Tracks','-v7.3');
    fprintf('[hand-off] wrote Tracks.mat from %s (%d cells).\n', tsSel, numel(Tracks));
elseif ~isfile('Tracks.mat')
    if isfile('TrackStruct.mat')
        S = load('TrackStruct.mat');           % var is 'Tracks'
        assert(isfield(S,'Tracks'),'TrackStruct.mat has no variable ''Tracks''.');
        Tracks = S.Tracks;                      %#ok<NASGU>
        save('Tracks.mat','Tracks','-v7.3');
        fprintf('[hand-off] wrote Tracks.mat from TrackStruct.mat (%d cells).\n',numel(Tracks));
    else
        error(['Neither Tracks.mat nor TrackStruct.mat in %s.\n' ...
               'Build one (Tab 4), or pick a TrackStruct file in the Run tab (e.g. a named build like Day1.mat).'],workDir);
    end
end
L = load('Tracks.mat'); Tracks = L.Tracks;      %#ok<NASGU>
PixSize = o.PixSize;

% Auto-detect JBM/Deff availability: the Deff branch needs external JBM Maps
% (Maps/*.mat) AND the external AssimilateTessIndex3. If absent, run the NoDeff
% path so the pipeline still completes on tracking-only data.
useJBM = o.JBM;
if o.JBM && ~(isfolder('Maps') && ~isempty(dir(fullfile('Maps','*.mat'))))
    warning('run_contactsite_analysis:noJBM', ...
        ['JBM/Deff requested but no Maps/*.mat found in %s — running the NoDeff ' ...
         '(no diffusion) path. Add JBM tessellation Maps to enable Deff.'], workDir);
    useJBM = false;
end

fprintf('\n=== ContactSites driver: %s ===\nJBM=%d  MitoOnly=%d  stages %s..%s\n\n', ...
    workDir,useJBM,o.MitoOnly,keys{i0},keys{iEnd});

for k = i0:iEnd
    key = keys{k}; typ = STAGES{k,2}; desc = STAGES{k,3};
    fprintf('---- stage %d/%d [%s] %s\n     %s\n',k,numel(keys),typ,key,desc);
    if ~isempty(o.ProgressFcn)
        try, o.ProgressFcn(k, numel(keys), key, typ, desc); catch, end   % live UI update between stages
    end

    switch key
      %======================= AUTOMATABLE STAGES =========================
      case 'density'
        selD = selectCells(Tracks, o.IncludeFiles);   % session selection ({}=all)
        DensityVisualization(Tracks(selD),PixSize,true);   % outputs named by .file, so a subset is safe
        if ~isfolder('Densities'), mkdir Densities; end
        if ~isempty(dir('*_rho.tif')), movefile('*_rho.tif','Densities'); end  % mapper reads them from Densities/
        fprintf('     -> Densities/*_rho.tif  (%d of %d cell(s))\n', nnz(selD), numel(Tracks));

      case 'locdens'
        selD = selectCells(Tracks, o.IncludeFiles);
        for i=find(selD)
            LocDensityFigIntUse(Tracks,i,PixSize);
        end

      case 'quickplot'
        % QuickPlotterTracks overlays tracks on MaxInt RGB QC images. Those are only
        % produced by the Fiji/Deff branch — on this pipeline they don't exist, and the
        % app's Import-QC tab already provides (better, interactive) track QC. So skip
        % cleanly when MaxInt is absent instead of throwing a scary warning every run.
        if exist(fullfile(pwd,'MaxInt'),'dir')
            try, QuickPlotterTracks; catch ME
                warning('QuickPlotterTracks failed (%s) — non-critical QC, continuing.',ME.message);
            end
        else
            fprintf('     (skipped — no MaxInt QC images on this pipeline; use the Import QC tab)\n');
        end

      case 'mapper'
        need_dir('csIDs','the Fiji CSidentifier output masks');
        need_dir('Densities','*_rho.tif from the density stage');
        if useJBM
            need_dir('Maps','JBM tessellation Maps_*_kmeans_60_nb_min_30.mat');
            ContactSiteMapper;
        else
            ContactSiteMapperNoDeff;
        end
        fprintf('     -> TrackData/*_Tracks.mat, TrackData/*_CSdata.mat, CSdata/*.tif\n');

      case 'part2'
        need_dir('TrackData','ContactSiteMapper output');
        % Inlined Part2 hand-off. The suite Part2.m calls `clear all`, which is
        % unsafe run from inside this driver's workspace. CStabulator builds
        % T + CSinfo; CellAccumulator reassembles Tracks from TrackData/*_Tracks.mat.
        old2 = cd('TrackData');
        try
            CStabulator; CellAccumulator;    %#ok<NASGU>  % -> T, CSinfo, Tracks
        catch ME2
            cd(old2); rethrow(ME2);
        end
        cd(old2);
        writetable(T,'CSstats.xlsx','WriteRowNames',true);
        save('CSindexing.mat','CSinfo');
        for ii=1:numel(Tracks)
            Tracks(ii).MitoCSindex = CSinfo(ii).CSindex; %#ok<AGROW>
        end
        save('Tracks_final.mat','Tracks','-v7.3');
        fprintf('     -> CSindexing.mat, Tracks_final.mat (with MitoCSindex), CSstats.xlsx\n');

      case 'snaprename'
        % Idempotent: CSdata/ holding this run's fresh mapper snaps (*_density.tif)
        % gets moved to CSsnaps/. A stale CSsnaps/ from a previous run is replaced
        % (the snaps are regenerated every mapper run), so re-running works.
        hasSnaps = isfolder('CSdata') && ~isempty(dir(fullfile('CSdata','*_density.tif')));
        if hasSnaps
            if isfolder('CSsnaps')
                warning('run_contactsite_analysis:replaceSnaps','Replacing existing CSsnaps/ with this run''s snaps.');
                rmdir('CSsnaps','s');
            end
            movefile('CSdata','CSsnaps'); mkdir CSdata;
            fprintf('     -> CSdata/ renamed to CSsnaps/, fresh CSdata/ created\n');
        else
            if ~isfolder('CSdata'), mkdir CSdata; end
            fprintf('     (no fresh density snaps in CSdata/ — assuming already renamed; continuing)\n');
        end

      case 'ensemble'
        if ~useJBM
            fprintf('     (skipped: no Deff without JBM data)\n');
        else
            need_file('Tracks_final.mat','Part2 output');
            if o.MitoOnly, CSensemble1; else, CSensemble2; end
            fprintf('     -> ensemble Deff (Din/Dout/Dother) for Prism/Excel\n');
        end

      case 'builder'
        need_dir('CSdata','refined CSdata from cs_refine');
        Lf = load('Tracks_final.mat'); Tracks = Lf.Tracks;   %#ok<NASGU>
        if useJBM
            CS = CS_builder(Tracks);                          %#ok<NASGU>
        else
            CS = CS_builderNoJBM(Tracks);                     %#ok<NASGU>
        end
        % MitoOnly refine writes CSdata/*_mito_CSdata.mat, but the builder reads *_CSdata.mat — guard
        % against the silent-empty result that mismatch produces (see docs/CODE_REVIEW.md M9).
        if numel(CS)==0 && o.MitoOnly && ~isempty(dir(fullfile('CSdata','*_mito_CSdata.mat')))
            error(['builder produced 0 contact sites: MitoOnly refine wrote CSdata/*_mito_CSdata.mat but ' ...
                   'CS_builder reads *_CSdata.mat. Re-refine without MitoOnly (or rename the _mito_ files) ' ...
                   'so the builder can find them.']);
        end
        fprintf('     -> CS_final.mat (%d contact sites)\n',numel(CS));

      case 'accum'
        need_file('CS_final.mat','CS_builder output');
        try
            if useJBM, ConditionAccumulatorFinal; else, ConditionAccumulatorFinalnoJBM; end
        catch ME
            warning('ConditionAccumulator failed (%s).',ME.message);
        end
        fprintf('     -> CSdata.xlsx + per-CS reference images\n');

      case 'csid'
        % In-MATLAB CS identification (replaces the Fiji CustomMaskMaker ->
        % CSidentifier -> CSchecker -> CSrepairer gate). Interactive per cell,
        % blocks for the user, then the loop falls through to 'mapper'.
        need_dir('Densities','*_rho.tif from the density stage');
        cs_identify(workDir,'Parent',o.UIParent, ...
            'MitoDir',o.MitoDir,'MitoPat',o.MitoPat,'MitoStrip',o.MitoStrip, ...
            'ErDir',o.ErDir,'ErPat',o.ErPat, ...
            'IncludeFiles',o.IncludeFiles);      % session cell selection (Experiment "work" ticks)
        need_dir('csIDs','cs_identify output (*_CSsites.txt)');
        fprintf('     -> csIDs/*_CSsites.txt\n');

      case 'refiner'
        % In-MATLAB, mouse-driven CS refinement (replaces the Wacom CSrefiner1/2
        % gate). Interactive per CS, then falls through to ensemble -> builder.
        need_dir('TrackData','raw *_CSdata.mat from the mapper');
        need_file('Tracks_final.mat','Part2 output (matrix source)');
        if ~isfolder('CSdata'), mkdir CSdata; end   % snaprename left CSdata/ fresh
        cs_refine(workDir,'MitoFlag',tern(o.MitoOnly,1,0),'OnlyCS',o.OnlyCS,'OnlyCell',o.OnlyCell,'Parent',o.UIParent, ...
            'MitoDir',o.MitoDir,'MitoPat',o.MitoPat,'MitoStrip',o.MitoStrip,'ErDir',o.ErDir,'ErPat',o.ErPat);
        need_dir('CSdata','cs_refine output (refined *_CSdata.mat)');
        fprintf('     -> CSdata/*_CSdata.mat (refined)\n');
    end
end

state.stopped_at = keys{iEnd};
state.reason = 'reached StopAfter / end of automated range';
if iEnd < numel(keys), state.next = keys{iEnd+1}; end
fprintf('\n=== driver finished at stage "%s". ',state.stopped_at);
if ~isempty(state.next)
    fprintf('Next: "%s".\n',state.next);
else
    fprintf('\nAll driver stages complete. Optional downstream (manual): NPB/Bayesian branch,\n');
    fprintf('CS averager/AvgAccumulator, DwellTime/EntryExit, AssignCSindexByCell — see README.\n');
end
end

% ============================ helpers ==================================
function need_dir(d,what)
  if ~isfolder(d) || isempty(dir(fullfile(d,'*')))
    error('Missing folder "%s/" (%s). Cannot run this stage.',d,what);
  end
end
function need_file(f,what)
  if ~isfile(f), error('Missing file "%s" (%s). Cannot run this stage.',f,what); end
end
function p = cs_path(name)
  p = which(name);
  if isempty(p), error('%s not on the MATLAB path. Pass ''SuitePath''.',name); end
end
function r = tern(c,a,b), if c, r=a; else, r=b; end, end

function sel = selectCells(Tracks, inc)
% Logical mask over Tracks for the session's IncludeFiles selection ({} = all cells).
% Matches on the cell's tracks-file name by exact name or containment (robust to prefixes).
n = numel(Tracks); sel = true(1,n);
if isempty(inc), return; end
if ischar(inc), inc = {inc}; end
for i = 1:n
    f = Tracks(i).file;
    sel(i) = any(cellfun(@(x) ~isempty(x) && (strcmpi(x,f) || contains(f,x) || contains(x,f)), inc));
end
if ~any(sel), sel = true(1,n); end   % nothing matched -> run all rather than silently skip everything
end
