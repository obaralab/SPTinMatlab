function cs_step_roundtrip_smoke()
% Verify the STEP bridge round-trip: MATLAB export -> run_step.py (rolling fallback) -> MATLAB import,
% and that a track which SLOWS inside the contact site shows a lower D inside than outside (Din < Dout).
here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
td = fullfile(tempdir,'cs_step_rt'); if isfolder(td), rmdir(td,'s'); end
ana = fullfile(td,'analysis'); mkdir(ana);

% --- mock: 1 site (circle r=0.5 µm at centre [5 5]), 2 member tracks ---
th = linspace(0,2*pi,49)'; rb = [0.5*cos(th), 0.5*sin(th)];        % boundary rel. centre
nF = 40; frames = (0:nF-1)';
x1 = zeros(nF,1); y1 = zeros(nF,1); x1(1) = 2; y1(1) = 0;          % track 1: enters + SLOWS inside
for i = 2:nF
    if hypot(x1(i-1),y1(i-1)) > 0.5
        n = hypot(x1(i-1),y1(i-1)); x1(i) = x1(i-1) - 0.15*x1(i-1)/n; y1(i) = y1(i-1) - 0.15*y1(i-1)/n;
    else
        x1(i) = x1(i-1) + 0.008*sin(3*i); y1(i) = y1(i-1) + 0.008*cos(3*i);   % tiny steps inside
    end
end
x2 = linspace(-2,2,nF)'; y2 = 0.3*sin(linspace(0,4*pi,nF))';       % track 2: fast passer-through
CSmat = nan(nF,2,3);
CSmat(:,1,1)=frames; CSmat(:,1,2)=x1; CSmat(:,1,3)=y1;
CSmat(:,2,1)=frames; CSmat(:,2,2)=x2; CSmat(:,2,3)=y2;
CSW = struct('file','mock','cellIndex',1,'csID',1,'window',1,'winFrames',[0 nF-1], ...
    'center',[5 5],'refboundary',rb,'dt',0.02,'tracks',[1 2],'CSmatrix',CSmat);

cs_step_export(CSW, ana);
assert(isfile(fullfile(ana,'step','step_tracks.csv')), 'export did not write step_tracks.csv');

cmd = sprintf('python3 "%s" --in "%s" --out "%s" --win 7', fullfile(here,'run_step.py'), ...
    fullfile(ana,'step','step_tracks.csv'), fullfile(ana,'step','step_predictions.csv'));
[st,out] = system(cmd); fprintf('%s\n', strtrim(out));
assert(st==0, 'run_step.py failed: %s', out);

S = cs_step_import(ana);
fprintf('imported %d member tracks:\n', numel(S));
for k = 1:numel(S)
    fprintf('  %s : Din=%.4g Dout=%.4g ratio=%.2f (in %d / out %d) [%s]\n', ...
        S(k).track_uid, S(k).Din, S(k).Dout, S(k).ratio, S(k).nIn, S(k).nOut, S(k).method);
end
i1 = find(arrayfun(@(s) s.trackCol==1, S), 1);
assert(~isempty(i1), 'track 1 missing from import');
assert(S(i1).Din < S(i1).Dout, 'the slowing track should have lower D inside the site (Din<Dout)');
assert(strcmp(S(i1).method,'rolling'), 'expected the rolling fallback method');
rmdir(td,'s');
fprintf('\nSTEP ROUND-TRIP SMOKE PASSED.\n');
end
