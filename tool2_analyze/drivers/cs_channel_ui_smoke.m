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

fprintf('\n========== PART D: the dwell overlay cannot alias one channel onto another ==========\n');
% The bug: dwellOrgMask picked its stack with `if strcmp(which,'mito'), p = da.mitoPath; else, p =
% da.erPath; end` and cached under `segIdx*10 + (mito?1:2)`. EVERY non-mito channel therefore read
% the ER stack and shared the ER cache slot — the wrong mask under the right label, silently.
src = fileread(fullfile(fileparts(here),'app','spt_analyze_app.m'));
assert(~contains(src, "segIdx*10"), 'the numeric orgCache key that aliased channels is back');
assert(~contains(src, "if strcmp(which,'mito'), p = da.mitoPath; else, p = da.erPath; end"), ...
    'dwellOrgMask still picks its stack with a two-way mito/ER test');
assert(contains(src, "sprintf('%s@%d', which, segIdx)"), 'the cache key is not per-channel');
assert(contains(src, "'KeyType','char'"), 'orgCache must be keyed by string, not by a packed number');
% Cache keys for three channels across two frames must all be distinct.
keys = {};
for kk = {'er','mito','lyso'}
    for f = [1 2]
        keys{end+1} = sprintf('%s@%d', kk{1}, f); %#ok<AGROW>
    end
end
assert(numel(unique(keys))==numel(keys), 'cache keys collide across channels');
fprintf('  cache key is "<key>@<page>": %s — all distinct\n', strjoin(keys, ' '));

% Colours: within a project no two channels may share one, in EITHER panel's pin set.
PICK = struct('er',[0.25 1.00 0.50], 'mito',[1.00 0.30 0.85]);   % picker: contours
DWEL = struct('er',[0.20 1.00 0.35], 'mito',[1.00 0.25 1.00]);   % dwell: translucent fills
for pins = {PICK, DWEL}
    cols = cell2mat(arrayfun(@(i) cs_channel_colour(sub2key(i), i, pins{1}), (1:4)', 'UniformOutput', false));
    assert(size(unique(cols,'rows'),1)==4, 'two channels share a colour in one of the panels');
end
% The pinned pairs differ between panels on purpose (published figures), but the ROTA is shared, so
% a newly declared channel looks the same in both.
assert(isequal(cs_channel_colour('lyso',3,PICK), cs_channel_colour('lyso',3,DWEL)), ...
    'a new channel must get the same rota colour in every panel');
assert(~isequal(cs_channel_colour('er',1,PICK), cs_channel_colour('er',1,DWEL)), ...
    'premise: the two panels pin ER differently');
fprintf('  4 channels -> 4 distinct colours in both panels; the rota is shared, the pins are not\n');

fprintf('\ncs_channel_ui_smoke: PASS\n');
end

function k = sub2key(i)
ks = {'er','mito','lyso','perox'};
k = ks{min(max(i,1), numel(ks))};
end

% ------------------------------------------------------------------------------------------------
function c = colourOf(key, idx)
% The picker's pins, through the SHARED palette function — not a reimplementation of it. This used
% to duplicate the rota, which would have let the two drift apart silently.
c = cs_channel_colour(key, idx, struct('er',[0.25 1.00 0.50], 'mito',[1.00 0.30 0.85]));
end

function closeIfThere(f)
if ~isempty(f) && isgraphics(f), try close(f); catch, end, end
end

function cleanUp(d)
if isfolder(d), try rmdir(d,'s'); catch, end, end
end
