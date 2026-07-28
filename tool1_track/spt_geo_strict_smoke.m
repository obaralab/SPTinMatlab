function spt_geo_strict_smoke()
%SPT_GEO_STRICT_SMOKE  Regression test for the STRICT ER-geodesic linking rule (Tool 1).
%
%   spt_geo_strict_smoke
%
% The contract under test: in mode='geodesic', a detection that is not on its OWN frame's ER
% support NEVER appears in a track — by any route, including a missing ER mask and gap closing.
% Strict mode fails CLOSED: no mask means "forbid", never "no constraint".
%
% Each case below corresponds to a hole that was found open by audit; several of them
% (empty mask, short mask cell, erAware=false, gap-close across a severed ER, gap-close between
% two off-ER fragments) previously admitted off-ER detections into tracks.
%
% Synthetic 40x40 field, ER = a horizontal band on rows 18:22. Uses pxUm = 1 so µm == px.
fprintf('\n=== spt_geo_strict_smoke — strict ER-geodesic contract ===\n');
H = 40; W = 40; PX = 1; LINK = 5; GAP = 12; nFail = 0;

band = false(H,W); band(18:22, :) = true;              % intact ER band
onY  = 20;                                             % on the band
offY = 5;                                              % clearly off it

% ---------------------------------------------------------------- basics
mv  = @(y) arrayfun(@(k) [5+3*(k-1), y, 1], 1:5, 'uni', 0);   % 5 frames, 3 px/frame at height y
sup5 = repmat({band}, 1, 5);

nFail = nFail + chk('S5  on-ER spot links normally (strict must not be broken outright)', ...
    ntracks(mv(onY),  sup5, LINK, GAP, 0, PX, 'geodesic'), 1);
nFail = nFail + chk('S1  off-ER spot is excluded', ...
    ntracks(mv(offY), sup5, LINK, GAP, 0, PX, 'geodesic'), 0);
nFail = nFail + chk('S1  ...but euclid still tracks it (control: mode really is the difference)', ...
    ntracks(mv(offY), sup5, LINK, GAP, 0, PX, 'euclid'), 1);
nFail = nFail + chk('S1  ...and penalty still tracks it (soft mode unchanged by this fix)', ...
    ntracks(mv(offY), sup5, LINK, GAP, 0, PX, 'penalty'), 1);

both = arrayfun(@(k) [5+3*(k-1), offY, 1; 5+3*(k-1), onY, 1], 1:5, 'uni', 0);
[tr, inf1] = spt_track(both, sup5, LINK, GAP, 0, PX, true, 3, 'geodesic');
nFail = nFail + chk('S1b mixed frame keeps only the on-ER track', numel(tr), 1);
nFail = nFail + chk('S1b ...and reports the excluded off-ER detections', inf1.nDetsOffEr, 5);
if numel(tr) == 1
    nFail = nFail + chk('S1b ...and the kept track is the on-ER one', all(tr{1}(:,3) == onY), true);
end

% ---- S6 the 1 px registration slack: 1 px off the band is on, 2 px off is not
nFail = nFail + chk('S6  1 px outside the mask is still on-ER (registration slack)', ...
    ntracks(mv(17), sup5, LINK, GAP, 0, PX, 'geodesic'), 1);
nFail = nFail + chk('S6  2 px outside the mask is off-ER', ...
    ntracks(mv(16), sup5, LINK, GAP, 0, PX, 'geodesic'), 0);

% ------------------------------------------------- FAIL CLOSED on a missing mask
nFail = nFail + chk('S2  ALL masks empty -> nothing tracked (was: full off-ER track)', ...
    ntracks(mv(offY), repmat({[]},1,5), LINK, GAP, 0, PX, 'geodesic'), 0);
nFail = nFail + chk('S2b supports = {} -> nothing tracked', ...
    ntracks(mv(offY), {}, LINK, GAP, 0, PX, 'geodesic'), 0);
s3 = sup5; s3{3} = [];
nFail = nFail + chk('S3  one blank middle mask -> no off-ER link (was: a 2-point off-ER track)', ...
    ntracks(mv(offY), s3, LINK, GAP, 0, PX, 'geodesic'), 0);
nFail = nFail + chk('S3b supports SHORTER than the movie -> no off-ER link in the tail frames', ...
    ntracks(mv(offY), repmat({band},1,3), LINK, GAP, 0, PX, 'geodesic'), 0);
[~, inf2] = spt_track(mv(offY), s3, LINK, GAP, 0, PX, true, 3, 'geodesic');
nFail = nFail + chk('S3  ...and the blank frame is counted for provenance', inf2.nFramesNoErMask, 1);

% A blank mask must not quietly drop ON-ER spots either — it must be visible as a reported gap.
nFail = nFail + chk('S3c on-ER track survives around a single blank frame (as 2 pieces, not 1)', ...
    ntracks(mv(onY), s3, LINK, GAP, 0, PX, 'geodesic'), 2);

% Scenario A — caller passes erAware=false with mode='geodesic' (spt_track re-forces erAware)
nFail = nFail + chk('A   erAware=false + geodesic -> still fails closed', ...
    numel(spt_track(mv(offY), repmat({[]},1,5), LINK, GAP, 0, PX, false, 3, 'geodesic')), 0);

% ------------------------------------------------------------- GAP CLOSING
% Two on-ER segments, frames 1-3 and 6-8 (a 2-frame hole), 10 px apart.
segs = cell(1,8);
mkseg = @(y) deal_segments(y);
[segs_on, sup8] = mkseg(onY);   %#ok<ASGLU>
segs = segs_on;

nFail = nFail + chk('GC1 intact ER: a legitimate gap close still happens (must not over-restrict)', ...
    ntracks(segs, repmat({band},1,8), LINK, GAP, 2, PX, 'geodesic'), 1);

sev = band; sev(:, 21:23) = false;                      % ER severed by a 3 px break
nFail = nFail + chk('S4b severed ER: gap close is refused (was: one track jumping the break)', ...
    ntracks(segs, repmat({sev},1,8), LINK, GAP, 2, PX, 'geodesic'), 2);

wide = band; wide(:, 19:28) = false;                    % 10 px break
nFail = nFail + chk('S4a wide ER break: gap close refused', ...
    ntracks(segs, repmat({wide},1,8), LINK, GAP, 2, PX, 'geodesic'), 2);

[segs_off, ~] = mkseg(6);                               % both fragments entirely off the ER
nFail = nFail + chk('S4c off-ER fragments, masks present -> nothing tracked', ...
    ntracks(segs_off, repmat({band},1,8), LINK, GAP, 2, PX, 'geodesic'), 0);
nFail = nFail + chk('S4d off-ER fragments, masks EMPTY -> nothing tracked (was: one 6-point track)', ...
    ntracks(segs_off, repmat({[]},1,8), LINK, GAP, 2, PX, 'geodesic'), 0);

% Soft mode must be untouched by all of this.
nFail = nFail + chk('penalty mode still gap-closes across the severed ER (soft, by design)', ...
    ntracks(segs, repmat({sev},1,8), LINK, GAP, 2, PX, 'penalty'), 1);

% ------------------------------------------------------- direct cost-matrix probe
onP = [10 onY 1]; offP = [10 offY 1]; onQ = [13 onY 1]; offQ = [13 offY 1];
C = spt_link_cost_geo(onP, onQ, LINK, band, 3);
nFail = nFail + chk('cost on->on is finite', isfinite(C), true);
nFail = nFail + chk('cost on->off is Inf',  isinf(spt_link_cost_geo(onP, offQ, LINK, band, 3)), true);
nFail = nFail + chk('cost off->on is Inf',  isinf(spt_link_cost_geo(offP, onQ, LINK, band, 3)), true);
nFail = nFail + chk('cost with NO mask is Inf (fail closed)', ...
    isinf(spt_link_cost_geo(onP, onQ, LINK, [], 3)), true);
% target judged against its OWN frame's ER: source on frame-t ER, target where the ER has retracted
gone = false(H,W); gone(18:22, 1:11) = true;            % frame t+1: ER present only up to x=11
nFail = nFail + chk('target off its OWN frame ER is Inf (ER retracted between frames)', ...
    isinf(spt_link_cost_geo(onP, onQ, LINK, band, 3, gone)), true);

fprintf('\n');
if nFail > 0
    error('spt_geo_strict_smoke: %d assertion(s) FAILED — the strict ER-geodesic contract is broken.', nFail);
end
fprintf('ALL STRICT ER-GEODESIC ASSERTIONS PASSED.\n\n');
end

% =========================================================================
function [segs, sup] = deal_segments(y)
% Two 3-frame segments at height y: frames 1-3 (x = 14,16,18) and frames 6-8 (x = 28,30,32).
segs = cell(1,8);
xs1 = [14 16 18]; xs2 = [28 30 32];
for k = 1:3, segs{k}   = [xs1(k), y, 1]; end
for k = 1:3, segs{5+k} = [xs2(k), y, 1]; end
segs{4} = zeros(0,3); segs{5} = zeros(0,3);
sup = [];
end

function n = ntracks(dets, supports, linkUm, gapUm, maxGap, px, mode)
n = numel(spt_track(dets, supports, linkUm, gapUm, maxGap, px, ~strcmp(mode,'euclid'), 3, mode));
end

function bad = chk(name, got, want)
ok = isequal(got, want) || (islogical(want) && isequal(logical(got), want));
if ok, fprintf('  ok    %-72s (%s)\n', name, num2str(double(got)));
else,  fprintf('  FAIL  %-72s got %s, want %s\n', name, num2str(double(got)), num2str(double(want)));
end
bad = double(~ok);
end
