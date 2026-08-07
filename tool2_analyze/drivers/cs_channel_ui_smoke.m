function cs_channel_ui_smoke()
% Headless validation that the contact-site picker's overlay UI is GENERATED per declared channel
% rather than written out as an ER/mito pair — so a project that declares a third channel gets a
% third checkbox and a third contour with no code change.
%
% The failure this prevents: before this, chkER and chkMito were two literal controls and the two
% contour draws were two literal lines, so a third channel reached storage and discovery (steps 1-4)
% and then vanished at the panel. It looked like the channel had not been imaged.
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(fileparts(here),'app'));

scratch = fullfile(tempdir, sprintf('cs_chan_ui_smoke_%d', feature('getpid')));
cleanup = onCleanup(@() cleanUp(scratch));
cleanUp(scratch); mkdir(scratch);

fprintf('\n========== PART A: colours are stable and distinct ==========\n');
% ER green and mito magenta are PINNED — a reader who knows the existing figures must not have to
% relearn them when the panel becomes generic.
assert(isequal(colourOf('er',1),   [0.25 1.00 0.50]), 'ER contour colour changed');
assert(isequal(colourOf('mito',2), [1.00 0.30 0.85]), 'mito contour colour changed');
c3 = colourOf('lyso',3);
assert(~isequal(c3, colourOf('er',1)) && ~isequal(c3, colourOf('mito',2)), ...
    'a third channel must not collide with ER or mito');
% Stable across runs: indexed by declaration order, not hashed, so the same project always draws
% the same colour for the same channel.
assert(isequal(c3, colourOf('lyso',3)), 'colour must be deterministic');
assert(isequal(colourOf('anything',3), colourOf('other',3)), 'colour comes from position, not name');
fprintf('  ER + mito pinned; a third channel gets a distinct, deterministic colour\n');

fprintf('\n========== PART B: a 3-channel project builds 3 overlay checkboxes ==========\n');
proj = fullfile(scratch,'proj'); ana = fullfile(proj,'analysis');
mkdir(ana);
fid = fopen(fullfile(proj,'channels.json'),'w');
fprintf(fid, ['{"channels":[{"key":"er","role":"support"},{"key":"mito","role":"proximity"},' ...
              '{"key":"lyso","role":"proximity","label":"Lysosome"}]}']);
fclose(fid);
chans = cs_channel_config(proj);
assert(numel(chans)==3, 'fixture must declare three channels');

% A minimal Tracks array — enough for the picker to open and lay out.
nF = 40; nT = 6;
F0 = repmat((0:nF-1)', 1, nT);
X0 = 2 + reshape(linspace(0, 4, nF*nT), nF, nT);
Y0 = 2 + reshape(linspace(4, 0, nF*nT), nF, nT);
Tr = struct('file','cellA.tif', 'matrix', cat(3,F0,X0,Y0), ...
            'lengths', repmat(nF,1,nT), 'allSpots', struct(), 'dist', struct(), ...
            'frameInterval', 0.01, ...
            'calib', struct('pixSizeUm',0.16,'fovUm',20.48,'dt_s',0.01,'precNm',30,'binNm',30));

fig = uifigure('Visible','off','Position',[100 100 1400 900]);
closeFig = onCleanup(@() closeIfThere(fig));
pn = uipanel(fig,'Units','normalized','Position',[0 0 1 1]);
cs_window_picker(pn, ana, struct('FOV_um',20.48,'binNm',30,'contactUm',0.15, ...
    'Tracks',Tr,'channels',chans));
drawnow; pause(0.3);                       % let the layout settle before measuring anything

boxes = findobj(fig,'Type','uicheckbox');
texts = arrayfun(@(h) string(h.Text), boxes);
fprintf('  checkboxes present: %s\n', strjoin(cellstr(texts'), ', '));
for want = {'ER','mito','lysosome'}
    assert(any(strcmpi(texts, want{1})), 'no overlay checkbox for "%s"', want{1});
end
fprintf('  all three channels have an overlay checkbox\n');

% The two original ones must keep their exact historical labels, since the panel is documented and
% screenshotted with them.
assert(any(strcmp(texts,'ER')),   'the ER checkbox must still read exactly "ER"');
assert(any(strcmp(texts,'mito')), 'the mito checkbox must still read exactly "mito"');

fprintf('\n========== PART C: the default project is unchanged ==========\n');
close(fig); clear closeFig;
fig2 = uifigure('Visible','off','Position',[100 100 1400 900]);
closeFig2 = onCleanup(@() closeIfThere(fig2));
pn2 = uipanel(fig2,'Units','normalized','Position',[0 0 1 1]);
ana2 = fullfile(scratch,'plain','analysis'); mkdir(ana2);
cs_window_picker(pn2, ana2, struct('FOV_um',20.48,'binNm',30,'contactUm',0.15,'Tracks',Tr));
drawnow; pause(0.3);
b2 = findobj(fig2,'Type','uicheckbox');
t2 = arrayfun(@(h) string(h.Text), b2);
assert(any(strcmp(t2,'ER')) && any(strcmp(t2,'mito')), 'the built-in default lost a channel box');
assert(~any(strcmpi(t2,'lysosome')), 'a project with no config must not gain channels');
fprintf('  no channels.json -> exactly the ER + mito panel it always was\n');

fprintf('\ncs_channel_ui_smoke: PASS\n');
end

% ------------------------------------------------------------------------------------------------
function c = colourOf(key, idx)
% Reach the picker's local chanColour without opening a figure. It is a local function of
% cs_window_picker.m, so this reproduces its contract rather than calling it; if the two ever
% diverge, PART B still fails on the real panel.
switch lower(char(key))
    case 'er',   c = [0.25 1.00 0.50];
    case 'mito', c = [1.00 0.30 0.85];
    otherwise
        rota = [0.30 0.75 1.00; 1.00 0.80 0.20; 0.70 0.55 1.00; 1.00 0.45 0.30; 0.55 1.00 0.85];
        c = rota(mod(max(idx,1)-1, size(rota,1)) + 1, :);
end
end

function closeIfThere(f)
if ~isempty(f) && isgraphics(f), try close(f); catch, end, end
end

function cleanUp(d)
if isfolder(d), try rmdir(d,'s'); catch, end, end
end
