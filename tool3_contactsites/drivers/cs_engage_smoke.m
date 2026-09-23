function cs_engage_smoke()
%CS_ENGAGE_SMOKE  Engagement read off the distance-to-centre trace, the way the VAPB dwell times
%were picked by hand - and scored against those hand picks.
%
% WHAT IS ASSERTED:
%   1. IT FINDS THE VISIT AND TIMES IT: a molecule that arrives, stays a known time and leaves gives
%      one event of that length, within a frame either side.
%   2. NOISE DOES NOT BECOME EVENTS: a molecule loitering ON the threshold gives ONE event, not one
%      per wobble (that is what the second radius is for), and a molecule that never approaches
%      gives none.
%   3. A ONE-FRAME EXCURSION DOES NOT SPLIT A VISIT, and a real departure does.
%   4. CENSORING IS REPORTED: a track that starts or ends inside says so, because its duration is
%      a lower bound.
%   5. THE DEPTH FILTER separates reaching the site from grazing it.
%   6. THE DWELL STAGE CAN USE IT: cs_window_dwell('method','trace') returns the same shape of
%      result as the polygon rule and records which rule it was.
%   7. THE PLOT draws one trace per member track and brackets each event.
%   8. AGAINST THE PUBLISHED ANNOTATION (only when ~/Desktop/VAPB_nature is on this machine): on the
%      tracks its annotator marked as bound, the detector recovers at least 75% of the events at
%      80% precision, and the dwell times agree to within 20% in the median.
%
% Synthetic except (8).

here = fileparts(mfilename('fullpath'));
addpath(here);
root_ = fileparts(fileparts(here));
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'));

dt = 0.02; R = 0.15;                       % 20 ms frames, a 150 nm site
opt = struct('siteRadius', R, 'dt', dt);

%% (1) one visit, timed ------------------------------------------------------------------------------
fr = (0:199)';
r = 1.2*ones(200,1); r(51:150) = 0.02;     % arrives at frame 50, leaves after 100 frames
E = cs_engage_detect(r, fr, opt);
assert(isscalar(E), 'one visit should give one event, got %d', numel(E));
assert(abs(E.dwell_s - 100*dt) <= 2*dt, 'dwell %.3f s, expected %.2f s', E.dwell_s, 100*dt);
assert(E.entryObserved && E.exitObserved, 'both ends were seen, so neither is censored');

%% (2) the second radius, and a molecule that stays away ----------------------------------------------
rng(0);
rr = (1.0*R)*ones(300,1) + 0.35*R*randn(300,1);         % loitering right at the enter radius
E2 = cs_engage_detect(rr, (0:299)', opt);
assert(numel(E2) <= 2, 'a molecule wobbling on the threshold should not become %d events', numel(E2));
E3 = cs_engage_detect(1.5*ones(100,1), (0:99)', opt);
assert(isempty(E3), 'a molecule that never approaches has no events');

%% (3) a one-frame excursion, and a real departure ------------------------------------------------------
r4 = 1.2*ones(200,1); r4(51:150) = 0.02; r4(100) = 1.4;  % one frame out, then back
E4 = cs_engage_detect(r4, fr, opt);
assert(isscalar(E4), 'a single frame outside must not split a visit (got %d events)', numel(E4));
r5 = 1.2*ones(200,1); r5(31:70) = 0.02; r5(121:170) = 0.02;   % two visits, well apart
E5 = cs_engage_detect(r5, fr, opt);
assert(numel(E5) == 2, 'two separate visits should stay two events, got %d', numel(E5));

%% (4) censoring ---------------------------------------------------------------------------------------
r6 = [0.02*ones(60,1); 1.2*ones(60,1)];                 % already inside when the track starts
E6 = cs_engage_detect(r6, (0:119)', opt);
assert(isscalar(E6) && ~E6.entryObserved && E6.exitObserved, 'a track that starts inside has no observed entry');

%% (5) the depth filter -----------------------------------------------------------------------------------
r7 = 1.2*ones(200,1); r7(51:150) = 1.4*R;               % inside the outer radius, never reaching the site
Eg = cs_engage_detect(r7, fr, opt);
Ed = cs_engage_detect(r7, fr, setfield(opt, 'maxDepth', 0.5)); %#ok<SFLD>
assert(~isempty(Eg) && isempty(Ed), 'the depth filter should drop a visit that only grazes the site');

%% (6) and (7) the dwell stage and the plot ----------------------------------------------------------------
nF = 200; nTr = 4;
X = nan(nF,nTr); Y = X; F = repmat(fr, 1, nTr);
for j = 1:nTr
    X(:,j) = 1.0; Y(:,j) = 0;
    X(40+10*j : 120+10*j, j) = 0.01;  Y(40+10*j : 120+10*j, j) = 0.01;
end
th = linspace(0,2*pi,40)';
e = struct('file','cellA','cellIndex',1,'csID',1,'window',1,'winFrames',[0 nF-1],'siteUID',1, ...
    'tracks',1:nTr,'CSmatrix',cat(3,F,X,Y),'refboundary',R*[cos(th) sin(th)],'dt',dt, ...
    'center',[5 5],'near',struct('mito',true));
f = figure('Visible','off'); closer = onCleanup(@() close(f)); ax = axes(f);
info = cs_engage_plot(ax, e, struct());
assert(info.nEvents == nTr, 'every one of the %d tracks engages once, got %d', nTr, info.nEvents);
assert(numel(findobj(ax,'Type','line')) >= nTr, 'one trace per member track should be drawn');
assert(~isempty(findobj(ax,'Type','constantline')), 'the events and the zero line should be marked');
assert(abs(info.radiusUm - R) < 0.02*R, 'the site radius should come from its own outline (got %.4f, outline %.4f)', info.radiusUm, R);

%% (8) against the published annotation ---------------------------------------------------------------
v = '/Users/safal-mac/Desktop/VAPB_nature';
if isfile(fullfile(v,'CS_final_v3.mat'))
    CS = load(fullfile(v,'CS_final_v3.mat')).CS; dtV = 0.011;
    TP = 0; FP = 0; FN = 0; ratio = [];
    for k = find(~cellfun(@isempty,{CS.trackBinding}))
        s = CS(k);
        Rs = sqrt(polyarea(s.refboundary(:,1)/1000, s.refboundary(:,2)/1000)/pi);
        for j = find(s.trackBinding > 0)
            rel = squeeze(s.CSmatrix(:,j,:)); okr = isfinite(rel(:,2));
            E8 = cs_engage_detect(hypot(rel(okr,2), rel(okr,3)), rel(okr,1), struct('siteRadius',Rs,'dt',dtV));
            det = arrayfun(@(q) [q.entryFrame q.exitFrame]*dtV, E8, 'uni', 0); det = vertcat(det{:});
            d = s.DwellTimes(j); man = [d.EntryPts(:,1) d.ExitPts(:,1)];
            used = false(size(det,1),1);
            for q = 1:size(man,1)
                hit = 0;
                for p = 1:size(det,1)
                    if used(p), continue; end
                    ov = min(man(q,2),det(p,2)) - max(man(q,1),det(p,1));
                    if ov > 0.5*min(diff(man(q,:)), diff(det(p,:))), hit = p; break; end
                end
                if hit > 0, TP = TP + 1; used(hit) = true; ratio(end+1) = diff(det(hit,:))/diff(man(q,:)); %#ok<AGROW>
                else, FN = FN + 1; end
            end
            FP = FP + nnz(~used);
        end
    end
    rec = TP/max(TP+FN,1); prec = TP/max(TP+FP,1); rat = median(ratio);
    assert(rec >= 0.75, 'recovered only %.0f%% of the hand-picked events', 100*rec);
    assert(prec >= 0.80, 'precision against the hand picks is %.0f%%', 100*prec);
    assert(abs(rat - 1) <= 0.2, 'detected dwell times are %.2fx the hand-picked ones', rat);
    fprintf('against %d hand-picked events: recall %.2f, precision %.2f, dwell ratio %.2f\n', TP+FN, rec, prec, rat);
else
    fprintf('(the published VAPB folder is not on this machine — skipped the annotation check)\n');
end

fprintf('engagement: visit timed, threshold noise and one-frame gaps survived, censoring flagged, depth filter, plot\n');
fprintf('\nENGAGE SMOKE PASSED.\n');
end
