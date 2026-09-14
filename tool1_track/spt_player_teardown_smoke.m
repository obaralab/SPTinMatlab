function spt_player_teardown_smoke()
%SPT_PLAYER_TEARDOWN_SMOKE  A queued timer tick must not fire into a player that has been torn down.
%
% THE CRASH. stop() prevents a timer firing again; it does NOT cancel a callback already in flight.
% Clicking a second track therefore delivers one more tick AFTER load_ has swapped R, reset the
% slider's Limits, or cleared the view. On the user's data that produced two errors from one tick:
%
%   'Value' must be a double scalar within the range of 'Limits'
%       — tick clamped sld.Value to the OLD nfr while Limits had already been set from the new movie
%   Dot indexing is not supported for variables of this type   (at imread(R.sptPath, fr))
%       — draw() reached composite() with R = [], because the clicked cell had no matched movie
%
% WHAT IS ASSERTED:
%   1. A TICK AFTER load([]) IS HARMLESS — the exact crash: play a track, clear the player, then
%      deliver the queued tick by hand. It must return quietly rather than dereference R.
%   2. A TICK AFTER A RELOAD IS HARMLESS — load a SHORTER movie while playing a longer one, then
%      tick. The stale `cur` must be clamped to the slider's CURRENT limits, not to a stale nfr.
%   3. PLAYING IS CLEARED ON TEARDOWN — the flag tick consults must be false once the view is gone,
%      or the guard depends on luck about which check runs first.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
root = fullfile(tempdir, sprintf('spt_playtd_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
mkdir(root);
cleanup = onCleanup(@() rmdir(root,'s'));

% Two movies of DIFFERENT length: reloading the short one while the long one plays is what makes
% `cur` stale relative to the slider's limits.
longTif  = fullfile(root,'long.tif');  writeStack(longTif, 40);
shortTif = fullfile(root,'short.tif'); writeStack(shortTif, 6);

fig = uifigure('Visible','off','Position',[1 1 700 500]);
closeFig = onCleanup(@() close(fig));
ctl = spt_track_movie(uipanel(fig));
assert(isstruct(ctl) && isfield(ctl,'load'), 'the player exposes no load hook');

ctl.load(mkR(longTif, 40), 0); drawnow;        % load_ ends by starting the timer and playing
tmr = playerTimer();
assert(~isempty(tmr), 'the player did not start a timer, so this test cannot deliver a queued tick');

%% (1) the exact crash: a tick delivered after the player was cleared -----------------------------
ctl.load([], 0); drawnow;                       % clicked a track whose cell has no matched movie
fireTick(tmr);                                  % the callback that was already in flight
fprintf('tick after load([]) survived\n');

%% (3) the flag tick consults must be false --------------------------------------------------------
% Re-load, then clear again, and confirm a SECOND queued tick is still harmless — if `playing` were
% left set, the guard would rest on whichever validity check happened to run first.
ctl.load(mkR(longTif, 40), 0); drawnow;
ctl.load([], 0); drawnow;
fireTick(tmr); fireTick(tmr);

%% (2) a tick delivered across a reload to a SHORTER movie -----------------------------------------
ctl.load(mkR(longTif, 40), 0); drawnow;
for k = 1:12, fireTick(playerTimer()); end      % advance `cur` well past the short movie's length
ctl.load(mkR(shortTif, 6), 0); drawnow;         % Limits are now [1 6] while cur is ~13
fireTick(playerTimer());
sld = pick(findobj(fig,'Type','uislider'), @(x) true, 'frame slider');
assert(sld.Value >= sld.Limits(1) && sld.Value <= sld.Limits(2), ...
    ['the slider sits at %.4g outside its limits [%g %g]. tick clamped to a stale frame count ' ...
     'instead of the slider''s current limits.'], sld.Value, sld.Limits(1), sld.Limits(2));
fprintf('tick across a reload kept the slider in [%g %g] at %.4g\n', sld.Limits(1), sld.Limits(2), sld.Value);

%% (4) A SUPERSEDED LOAD MUST NOT HALF-APPLY -------------------------------------------------------
% The reported crash: setting uicontrol properties on a uifigure can flush the graphics queue, so a
% queued click re-enters load_ INSIDE an earlier one, sets the shared R — to [] when that cell has no
% matched movie — and the outer call resumes with R gone, reaching composite() at the imshow line.
% The generation counter makes the superseded load abort. The property that must hold, and is
% checkable without racing anything, is that after two loads the player describes the SECOND: a
% half-applied first would leave the title, the slider limits and the image disagreeing.
ctl.load(mkR(longTif, 40), 0); drawnow;
ctl.load(mkR(shortTif, 6), 0); drawnow;
sld2 = pick(findobj(fig,'Type','uislider'), @(x) true, 'frame slider');
assert(isequal(sld2.Limits, [1 6]), ...
    ['the slider limits are [%g %g] after loading the 6-frame movie last. The earlier load left its ' ...
     'state behind, so the controls describe a different movie from the image.'], ...
    sld2.Limits(1), sld2.Limits(2));
axAll = findobj(fig,'Type','axes');
ttl = '';
for k = 1:numel(axAll)
    t = char(string(axAll(k).Title.String));
    if contains(t,'frames'), ttl = t; break; end
end
assert(contains(ttl,'of 6 frames'), ...
    'the title reads "%s" — it should describe the 6-frame movie that was loaded last', ttl);
fprintf('superseded load did not half-apply: limits [1 6], title "%s"\n', ttl);

fprintf('\nPLAYER-TEARDOWN SMOKE PASSED.\n');
end

% ================================================================================================
function t = playerTimer()
% The player's playback timer. Named by MATLAB, so it is found by its period rather than a name.
t = [];
all_ = timerfindall;
for k = 1:numel(all_)
    if abs(all_(k).Period - 0.08) < 1e-9, t = all_(k); return; end
end
end

function fireTick(t)
% Deliver one callback BY HAND, which is what a queued in-flight tick amounts to. Any error here is
% the failure this test exists for, so it is reported rather than swallowed.
if isempty(t) || ~isvalid(t), return; end
fcn = t.TimerFcn;
if isempty(fcn), return; end
fcn(t, struct());
drawnow;
end

function R = mkR(tif, nfr)
n = min(nfr, 10);
R = struct('base','fixture','sptPath',tif,'erPath','','mitoPath','', ...
           'x', 8 + (1:n)'*0.5, 'y', 8 + (1:n)'*0.3, 'frame', (0:n-1)', 'trackId', zeros(n,1));
end

function writeStack(f, n)
for k = 1:n
    im = uint16(1000 + 200*rand(32,32));
    if k == 1, imwrite(im, f); else, imwrite(im, f, 'WriteMode','append'); end
end
end

function h = pick(hs, test, what)
hit = hs(arrayfun(@(x) safe(test,x), hs));
assert(~isempty(hit), 'could not find the %s', what);
h = hit(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
