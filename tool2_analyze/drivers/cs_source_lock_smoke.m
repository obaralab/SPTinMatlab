function cs_source_lock_smoke()
% Verify the density source is LOCKED to the picker's windows.source: a CSwindows.mat saved with
% source='tracked' makes cs_footprints_build + cs_window_mapper use the tracked matrix regardless of
% opts.src ('all').
here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fileparts(fileparts(here)));   % repo root, where spt_test_data lives
% Needs a REAL built project: the fixture below is carved out of one cell of Project/analysis.
src = spt_test_data(fullfile('Project','analysis'));
if isempty(src)
    fprintf('SKIP %s — test dataset not installed (see spt_test_data.m)\n', mfilename);
    return
end
tmp = fullfile(tempdir,'cs_srclock'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp); mkdir(fullfile(tmp,'csIDs')); mkdir(fullfile(tmp,'Densities'));
S = load(fullfile(src,'TrackStruct.mat')); fn=fieldnames(S); Tr=S.(fn{1});
Tracks = Tr(1); save(fullfile(tmp,'TrackStruct.mat'),'Tracks'); %#ok<NASGU>
base = regexprep(char(Tr(1).file),'\.[^.]*$','');
% copy the cell's CSsites + rho
copyfile(fullfile(src,'csIDs',[base '_CSsites.txt']), fullfile(tmp,'csIDs',[base '_CSsites.txt']));
Lr = dir(fullfile(src,'Densities',[base '*_rho.tif'])); copyfile(fullfile(Lr(1).folder,Lr(1).name), fullfile(tmp,'Densities',Lr(1).name));
% whole-movie window, source = 'tracked'
grid=921; SF=27.61/grid;
windows = struct('ranges',[-Inf Inf],'SF_umPerPx',SF,'grid',grid,'frameInterval',Tr(1).frameInterval,'source','tracked'); %#ok<NASGU>
save(fullfile(tmp,['Density_' base '_CSwindows.mat']),'windows');

% opts.src='all' should be OVERRIDDEN by windows.source='tracked'
F = cs_footprints_build(tmp, struct('save',false,'verbose',false,'src','all'));
srcs = unique({F.densSrc});
fprintf('cs_footprints_build densSrc = %s (expect tracked)\n', strjoin(srcs,','));
assert(numel(srcs)==1 && strcmp(srcs{1},'tracked'), 'source not locked to picker (footprints)');
CSW = cs_window_mapper(tmp, struct('save',false,'verbose',false,'src','all','useRefined',false));
msrcs = unique({CSW.densSrc});
fprintf('cs_window_mapper densSrc = %s (expect tracked)\n', strjoin(msrcs,','));
assert(numel(msrcs)==1 && strcmp(msrcs{1},'tracked'), 'source not locked to picker (mapper)');
fprintf('\nSOURCE-LOCK ASSERTIONS PASSED.\n');
end
