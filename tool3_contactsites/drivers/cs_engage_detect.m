function E = cs_engage_detect(r, frames, opts)
%CS_ENGAGE_DETECT  Find engagement events in a molecule's distance-to-centre trace, the way a person
%does by eye - without the person.
%
%   E = cs_engage_detect(r, frames)
%   E = cs_engage_detect(r, frames, opts)
%
% THE TRACE IS THE MEASUREMENT. For a member track of a contact site, r(t) is its distance from the
% site centre (um) at each localization; frames is when each was seen. Engagement looks like this:
% the trace falls to near zero, stays there while the molecule is held, and leaves. That is what the
% VAPB work marked BY HAND on this plot (DwellTimeManualv2.m: click the entry, click the exit), and
% it is what this does.
%
% THE RULE IS A SCHMITT TRIGGER WITH A MEMORY, which is the signal-processing form of what the eye
% is doing:
%   ENTER when r falls below rIn - close enough to be at the site.
%   STAY while r stays below rOut, a larger radius. Two thresholds, not one, because a single one
%     chatters: a molecule sitting AT the threshold enters and leaves on the noise alone, and each
%     wobble becomes a separate "event". rOut > rIn is what stops that.
%   TOLERATE a short excursion above rOut (up to gapFrames) without ending the event - a molecule
%     that steps out for one frame and comes back was never gone, and localization error alone
%     produces such steps. This is the difference between counting visits and counting noise.
%   END when it stays out longer than that; the event ends at the last localization inside.
%   KEEP events of at least minFrames localizations, so a single close approach is not a visit.
%
% opts (all optional; the radius ones may be given as a multiple of a site radius, see 'siteRadius'):
%   .siteRadius   um: the site's equivalent radius, sqrt(area/pi). When given, rIn and rOut default
%                 to 2.0x and 3.5x it - a site's own size is the only scale that means anything
%                 here. Without it they default to 0.30 / 0.53 um.
%   .rIn .rOut    um, absolute (override the above)
%   .dt           (NaN) seconds per frame; fills E.dwell_s and sets the two durations below
%   .minDuration_s (0.11) how long an event must last. IN SECONDS, because the thresholds that
%                 reproduce a person's picks are physical, not per-frame: the same 0.11 s is 10
%                 frames at 11 ms and 4 at 26.7 ms. .minFrames overrides it.
%   .gapTolerance_s (0.11) how long an excursion beyond rOut may last without ending the event.
%                 .gapFrames overrides it.
%   .maxDepth     (Inf) require the visit to REACH the site: rMin <= maxDepth x siteRadius. Off by
%                 default. The VAPB annotator's own picks reach 0.12 R while the approaches he did
%                 not count as binding only reach 0.42 R, so 0.4-0.6 here trades recall for
%                 precision against that stricter, binding-like definition (see the smoke).
%   .method       'hysteresis' (default) | 'steps'. 'steps' fits r(t) with the Kalafut-Visscher
%                 piecewise-constant model (spt_pbsa_steps) and calls every segment whose level is
%                 below rIn an event - no thresholds on single points at all, which suits a noisy
%                 trace, at the cost of needing a real step in r to see the boundary.
%
% OUTPUT E, one row per event (a struct array; empty struct when there are none):
%   entryIdx exitIdx     indices into r / frames
%   entryFrame exitFrame the frames they fall on
%   nLoc                 localizations in the event
%   dwellFrames          exitFrame - entryFrame + 1 (span, as cs_window_dwell counts it)
%   dwell_s              that times dt
%   rMin rMean           how close it got, and how close it stayed
%   entryObserved        false when the track was already inside at its first localization - the
%   exitObserved         same at the end. A censored event's duration is a lower bound, which is
%                        the distinction the VAPB classifier recorded by hand as entry/exit only.

if nargin < 3 || ~isstruct(opts), opts = struct(); end
r = r(:); frames = frames(:);
ok = isfinite(r) & isfinite(frames);
r = r(ok); frames = frames(ok);
E = emptyE();
if numel(r) < 2, return; end

R      = getf(opts, 'siteRadius', NaN);
if isfinite(R) && R > 0, dIn = 2.0*R; dOut = 3.5*R; else, dIn = 0.30; dOut = 0.53; end
rIn    = getf(opts, 'rIn', dIn);
rOut   = getf(opts, 'rOut', dOut);
dt     = getf(opts, 'dt', NaN);
fps    = @(sec, floorN) max(floorN, round(sec / dt));
if isfinite(dt) && dt > 0
    minF = getf(opts, 'minFrames', fps(getf(opts,'minDuration_s',0.11), 3));
    gapF = getf(opts, 'gapFrames', fps(getf(opts,'gapTolerance_s',0.11), 2));
else
    minF = getf(opts, 'minFrames', 3);
    gapF = getf(opts, 'gapFrames', 2);
end
maxDepth = getf(opts, 'maxDepth', Inf);
method = lower(getf(opts, 'method', 'hysteresis'));
if rOut < rIn, rOut = rIn; end

switch method
    case 'steps'
        S = spt_pbsa_steps(r, 'MinStep', 0);
        lev = S.fit; lev(~isfinite(lev)) = inf;
        inside = lev < rIn;                       % a SEGMENT is inside, not a point
    otherwise
        inside = false(size(r));
        state = false;
        for i = 1:numel(r)
            if ~state && r(i) < rIn, state = true;
            elseif state && r(i) > rOut, state = false;
            end
            inside(i) = state;
        end
end

% runs of "inside", with short gaps bridged
[a, b] = runs(inside);
k = 1;
while k < numel(a)
    gapLoc = a(k+1) - b(k) - 1;                               % localizations between the runs
    gapFr  = frames(a(k+1)) - frames(b(k)) - 1;               % frames, which is what tolerance means
    if gapLoc <= gapF && gapFr <= max(gapF, 1)
        b(k) = b(k+1); a(k+1) = []; b(k+1) = [];
    else
        k = k + 1;
    end
end

for k = 1:numel(a)
    i0 = a(k); i1 = b(k);
    if (i1 - i0 + 1) < minF, continue; end
    if isfinite(maxDepth) && isfinite(R) && min(r(i0:i1)) > maxDepth*R, continue; end   % it only grazed the site
    e = struct('entryIdx', i0, 'exitIdx', i1, 'entryFrame', frames(i0), 'exitFrame', frames(i1), ...
        'nLoc', i1 - i0 + 1, 'dwellFrames', frames(i1) - frames(i0) + 1, ...
        'dwell_s', (frames(i1) - frames(i0) + 1) * dt, ...
        'rMin', min(r(i0:i1)), 'rMean', mean(r(i0:i1)), ...
        'entryObserved', i0 > 1, 'exitObserved', i1 < numel(r));
    if isempty(fieldnames(E)) || isempty(E), E = e; else, E(end+1) = e; end %#ok<AGROW>
end
end

% =================================================================================================
function [a, b] = runs(m)
m = m(:)'; d = diff([false m false]);
a = find(d == 1); b = find(d == -1) - 1;
end

function E = emptyE()
E = struct('entryIdx',{},'exitIdx',{},'entryFrame',{},'exitFrame',{},'nLoc',{},'dwellFrames',{}, ...
           'dwell_s',{},'rMin',{},'rMean',{},'entryObserved',{},'exitObserved',{});
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
