function cs_engage_classify_smoke()
%CS_ENGAGE_CLASSIFY_SMOKE  Engaged or not, per member track - and the dwell-time histogram that
%pools the result and compares conditions.
%
% WHAT IS ASSERTED:
%   1. EVERY MEMBER TRACK IS A ROW, engaged or not. The tracks that never approach are the
%      denominator of "what fraction engaged", so leaving them out is not an option.
%   2. IT COUNTS ENGAGEMENTS PER TRACK: a track built to visit twice reports two.
%   3. THE THRESHOLD IS MONOTONE AND MEANS SECONDS: raising minEngage_s can only un-engage tracks,
%      never engage more, and a brief toucher drops out while a long stayer does not.
%   4. THE SITE TOTALS ARE THE TRACK ROWS: fracEngaged and engagePerTrack agree with perTrack.
%   5. CENSORING IS FLAGGED on a track still inside when it ends.
%   6. TAU SURVIVES CENSORING: on exponential visits truncated by the movie, the estimator recovers
%      the true mean while the mean of the OBSERVED durations is biased low - which is the reason it
%      is not just mean(dwell).
%  7b. THE TWO WAYS IT MISLEADS ARE SAID OUT LOUD: heavy censoring (tau then rests on the
%      exponential assumption, not on observed exits), and groups watched for unequal lengths of
%      time (a longer observation window alone lengthens dwells).
%   7. THE COMPARISON WORKS: two conditions with different tau are separated (p < 0.01) and two
%      samples of the SAME tau are not (p > 0.05), on a shared set of bins so the bars compare.
%   8. THE DENOMINATOR CAN BE WIDENED: the mapper calls a track a member only once it has been INSIDE
%      the outline, so "fraction engaged" over members is measured on a set already selected for
%      engaging. denominator 'box' adds the tracks that came into the neighbourhood box and never
%      entered, which is the set his 41%-engaged sites hold - and the fraction drops accordingly.
%   9. AGAINST THE PUBLISHED ANNOTATION (only when ~/Desktop/VAPB_nature is present): over his 1,312
%      hand-labelled member tracks the rule agrees on at least 78% of tracks, at >= 0.75 sensitivity
%      and >= 0.75 specificity, and on the tracks both call engaged it gets the NUMBER of
%      engagements within one at least 90% of the time.
%
% Synthetic except (8).

here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));

dt = 0.02; R = 0.15; nF = 400;
th = linspace(0,2*pi,60)';
bnd = R*[cos(th) sin(th)];

%% (1)-(5) the classification ------------------------------------------------------------------------
% six member tracks: two long stayers, one double-visitor, one brief toucher, one that stays away,
% one still inside when it ends
nTr = 6; X = nan(nF,nTr); Y = nan(nF,nTr); F = repmat((0:nF-1)',1,nTr);
X(:) = 1.0; Y(:) = 0;                                  % far away by default
X(51:150,1)  = 0.01;                                   % 100 frames = 2.0 s
X(51:200,2)  = 0.01;                                   % 150 frames = 3.0 s
X(41:90,3)   = 0.01; X(201:260,3) = 0.01;              % two visits
X(51:55,4)   = 0.01;                                   % 5 frames = 0.1 s, a touch
X(351:end,6) = 0.01;                                   % still there at the end
Y(~isnan(X) & X < 0.5) = 0.01;
e = struct('file','cellA','cellIndex',1,'csID',1,'window',1,'winFrames',[0 nF-1],'siteUID',1, ...
    'tracks',1:nTr,'CSmatrix',cat(3,F,X,Y),'refboundary',bnd,'dt',dt,'condition','ctrl', ...
    'near',struct('mito',true));
G = cs_engage_classify(e, struct('verbose',false));
assert(numel(G.perTrack) == nTr, 'every member track should get a row (%d of %d)', numel(G.perTrack), nTr);
eng = [G.perTrack.engaged];
assert(nnz(eng) == 4, 'four of the six tracks engage (two stayers, the double-visitor, the censored one), got %d', nnz(eng));
assert(~eng(4), 'a 0.1 s touch is not an engagement at the 0.30 s default');
assert(~eng(5), 'a track that never approaches cannot be engaged');
assert(G.perTrack(3).nEngage == 2, 'the double-visitor should report 2 engagements, got %d', G.perTrack(3).nEngage);
assert(abs(G.perTrack(1).longest_s - 100*dt) < 3*dt, 'the 2 s visit should be timed as such (%.2f)', G.perTrack(1).longest_s);
assert(G.perTrack(6).censored, 'a track still inside when it ends has a censored visit');
assert(~G.perTrack(1).censored, 'a visit seen to start and end is not censored');
assert(isfinite(G.perTrack(1).mobRatio) && G.perTrack(1).mobRatio < 1, ...
    'the held track moved less while it was there (ratio %.2f)', G.perTrack(1).mobRatio);

% (3) monotone in the threshold
n1 = nnz([cs_engage_classify(e, struct('verbose',false,'minEngage_s',0)).perTrack.engaged]);
n2 = nnz([cs_engage_classify(e, struct('verbose',false,'minEngage_s',1.0)).perTrack.engaged]);
n3 = nnz([cs_engage_classify(e, struct('verbose',false,'minEngage_s',5.0)).perTrack.engaged]);
assert(n1 >= nnz(eng) && nnz(eng) >= n2 && n2 >= n3, ...
    'raising the threshold must not engage more tracks (%d, %d, %d, %d)', n1, nnz(eng), n2, n3);
assert(n3 == 0, 'no visit here lasts 5 s, so nothing should be engaged');

% (4) the site row is the track rows
s = G.perSite;
assert(isscalar(s), 'one site-window in, one site row out');
assert(s.nTracks == nTr && s.nEngaged == nnz(eng), 'the site should count the tracks it saw');
assert(abs(s.fracEngaged - mean(eng)) < 1e-12, 'fracEngaged is nEngaged/nTracks');
assert(abs(s.engagePerTrack - sum([G.perTrack.nEngage])/nTr) < 1e-12, 'engagePerTrack is the mean over ALL member tracks');
assert(numel(G.dwell) == sum([G.perTrack.nEngage]), 'one dwell row per engagement');

%% (6) tau against censoring -------------------------------------------------------------------------
rng(7); tauTrue = 1.5; n = 4000; movie = 2.0;           % visits cut off at 2 s
d = exprnd(tauTrue, n, 1);
cens = d > movie; dObs = min(d, movie);
Dw = struct('dwell_s', num2cell(dObs), 'censored', num2cell(cens), 'condition', repmat({'x'}, n, 1));
Hc = cs_dwell_histogram(Dw, struct('group','condition'));
assert(abs(Hc.groups.tau - tauTrue) < 0.1*tauTrue, 'tau %.2f s, truth %.2f s', Hc.groups.tau, tauTrue);
assert(Hc.groups.meanObs < 0.85*tauTrue, ...
    'the mean of the observed durations should be visibly biased low (%.2f vs %.2f) — that is why tau exists', ...
    Hc.groups.meanObs, tauTrue);
Hn = cs_dwell_histogram(Dw, struct('group','none','useCensored',false));
assert(Hn.groups.tau < Hc.groups.tau, 'dropping the censored visits shortens the estimate');

%% (7) comparing conditions -------------------------------------------------------------------------
rng(17); m = 800;   % a seed whose same-distribution control is not borderline (p = 0.82)
mk = @(tau, name) struct('dwell_s', num2cell(exprnd(tau, m, 1)), ...
    'censored', num2cell(false(m,1)), 'condition', repmat({name}, m, 1));
A = mk(0.5,'ctrl'); B = mk(1.5,'drug'); A2 = mk(0.5,'ctrl2');
f = figure('Visible','off'); closer = onCleanup(@() close(f)); ax = axes(f);
H2 = cs_dwell_histogram([A(:); B(:)], struct('group','condition','ax',ax));
assert(numel(H2.groups) == 2, 'two conditions in, two groups out');
assert(isscalar(H2.test) && H2.test.p < 0.01, 'a 3x difference in tau should be detected (p = %.3g)', H2.test.p);
assert(numel(H2.groups(1).counts) == numel(H2.edges)-1, 'the counts sit on the shared bin edges');
assert(abs(sum(H2.groups(1).counts) - 1) < 0.05, 'probability normalization should make the bars sum to ~1');
assert(~isempty(findobj(ax,'Type','bar')), 'the histogram should be drawn');
H3 = cs_dwell_histogram([A(:); A2(:)], struct('group','condition'));
assert(H3.test.p > 0.05, 'two samples of the same distribution should not separate (p = %.3g)', H3.test.p);
Hs = cs_dwell_histogram([A(:); B(:)], struct('group','condition','ax',ax,'survival',true));
assert(~isempty(findobj(ax,'Type','stair')), 'the survival view should draw one curve per condition');
assert(abs(Hs.groups(2).tau/Hs.groups(1).tau - 3) < 0.6, 'the two taus should differ about 3x');

%% (7b) the warnings ---------------------------------------------------------------------------------
rng(21); tau3 = 1.5; win = 0.5;                          % watched for a third of the mean visit
d3 = exprnd(tau3, 1500, 1); c3 = d3 > win;
Dh = struct('dwell_s', num2cell(min(d3,win)), 'censored', num2cell(c3), ...
    'condition', repmat({'short movie'}, numel(d3), 1), 'trackObs_s', num2cell(repmat(win, numel(d3), 1)));
Hh = cs_dwell_histogram(Dh, struct('group','condition'));
assert(Hh.groups.censorHeavy && ~isempty(Hh.warnings), 'over half censored should be said out loud');
assert(any(contains(Hh.warnings,'exponential assumption')), 'the warning should say what tau then rests on: %s', strjoin(Hh.warnings,' / '));
nA = 600;
Du = [struct('dwell_s',num2cell(exprnd(0.5,nA,1)),'censored',num2cell(false(nA,1)), ...
             'condition',repmat({'longMovie'},nA,1),'trackObs_s',num2cell(repmat(8,nA,1))); ...
      struct('dwell_s',num2cell(exprnd(0.5,nA,1)),'censored',num2cell(false(nA,1)), ...
             'condition',repmat({'shortMovie'},nA,1),'trackObs_s',num2cell(repmat(2,nA,1)))];
Hu = cs_dwell_histogram(Du, struct('group','condition'));
assert(any(contains(Hu.warnings,'same length of time')), ...
    'groups watched for different lengths of time should be flagged: %s', strjoin(Hu.warnings,' / '));
assert(abs(Hu.groups(1).medianWindow_s - 8) < 1e-9, 'the observable window per group should be reported');

%% (8) the wider denominator -------------------------------------------------------------------------
% One cell: 4 tracks that enter the outline (3 of them stay), 3 that only visit the box, 3 far away.
cen = [5 5]; box = 1.0; nAll = 10;
XA = nan(nF,nAll); YA = nan(nF,nAll); FA = repmat((0:nF-1)',1,nAll);
XA(:) = cen(1) + 1.5; YA(:) = cen(2);                    % the last three, outside the box
for j = 1:3, XA(51:150,j) = cen(1)+0.01; YA(51:150,j) = cen(2)+0.01; end   % in, and staying
XA(51:55,4) = cen(1)+0.01; YA(51:55,4) = cen(2)+0.01;                      % in, briefly
for j = 1:4, XA(isnan(XA(:,j)),j) = cen(1)+1.5; YA(isnan(YA(:,j)),j) = cen(2); end
for j = 5:7                                              % in the box, never inside the outline,
    XA(:,j) = cen(1) + 0.40; YA(:,j) = cen(2) + 0.02;    % and never within 2R either
end
XA(isnan(XA)) = cen(1)+1.5; YA(isnan(YA)) = cen(2);
TS = struct('file','cellA','matrix',cat(3,FA,XA,YA),'frameInterval',dt, ...
    'lengths',repmat(nF,nAll,1),'trackIDs',(1:nAll)');
mem = 1:4;
eB = e;                                                  % the same site, with only the members mapped
eB.tracks = mem;
eB.CSmatrix = cat(3, FA(:,mem), XA(:,mem)-cen(1), YA(:,mem)-cen(2));
eB.refCenter = cen; eB.boxUm = box;
Gm = cs_engage_classify(eB, struct('verbose',false));
Gb = cs_engage_classify(eB, struct('verbose',false,'denominator','box','tracks',TS));
assert(numel(Gm.perTrack) == 4, 'members only: the 4 mapped tracks (got %d)', numel(Gm.perTrack));
assert(numel(Gb.perTrack) == 7, 'box: the 4 members plus the 3 that only visited the box (got %d)', numel(Gb.perTrack));
assert(all([Gb.perTrack(1:4).member]) && ~any([Gb.perTrack(5:7).member]), ...
    '.member should say which set each row came from');
assert(nnz([Gb.perTrack.engaged]) == 3, 'the box-only tracks never come within 2R, so still 3 engaged (got %d)', ...
    nnz([Gb.perTrack.engaged]));
assert(Gb.perSite.fracEngaged < Gm.perSite.fracEngaged, ...
    'widening the denominator must lower the engaged fraction (%.2f vs %.2f)', ...
    Gb.perSite.fracEngaged, Gm.perSite.fracEngaged);
assert(abs(Gb.perSite.fracEngaged - 3/7) < 1e-12 && abs(Gm.perSite.fracEngaged - 3/4) < 1e-12, ...
    'and it should be exactly 3 of 7 against 3 of 4');
assert(Gb.perSite.nMembers == 4, 'the site row should still say how many were members');
assert(numel(Gb.dwell) == numel(Gm.dwell), 'the engagements themselves are unchanged by the denominator');

%% (9) against the published annotation ---------------------------------------------------------------
v = '/Users/safal-mac/Desktop/VAPB_nature';
if isfile(fullfile(v,'CS_final_v3.mat'))
    CS = load(fullfile(v,'CS_final_v3.mat')).CS; dtV = 0.011;
    has = find(~cellfun(@isempty,{CS.trackBinding}));
    pred = []; truth = []; nP = []; nT = [];
    for k = has
        s = CS(k);
        E = struct('file',s.file,'cellIndex',s.cellIndex,'csID',s.csID,'window',1, ...
            'winFrames',[-Inf Inf],'siteUID',k,'tracks',1:numel(s.trackBinding), ...
            'CSmatrix',s.CSmatrix,'refboundary',s.refboundary/1000,'dt',dtV, ...
            'near',struct('mito',logical(s.MitoFlag)));
        Gk = cs_engage_classify(E, struct('verbose',false));
        if isempty(Gk.perTrack), continue; end
        cols = [Gk.perTrack.trackCol];
        tb = s.trackBinding(:);                       % his labels, one per member track
        pe = [Gk.perTrack.engaged]; ne = [Gk.perTrack.nEngage];
        pred  = [pred;  pe(:)];          %#ok<AGROW>
        truth = [truth; tb(cols) > 0];   %#ok<AGROW>
        nP = [nP; ne(:)];                %#ok<AGROW>
        nT = [nT; tb(cols)];             %#ok<AGROW>
    end
    pred = logical(pred(:)); truth = logical(truth(:));
    tp = nnz(pred&truth); fp = nnz(pred&~truth); fn = nnz(~pred&truth); tn = nnz(~pred&~truth);
    acc = (tp+tn)/numel(pred); sens = tp/(tp+fn); spec = tn/(tn+fp);
    both = pred & truth;
    within1 = mean(abs(nP(both) - nT(both)) <= 1);
    assert(numel(pred) > 1000, 'expected his ~1312 labelled member tracks, matched %d', numel(pred));
    assert(acc  >= 0.78, 'per-track agreement with the hand labels is only %.0f%%', 100*acc);
    assert(sens >= 0.75, 'sensitivity against the hand labels is %.2f', sens);
    assert(spec >= 0.75, 'specificity against the hand labels is %.2f', spec);
    assert(within1 >= 0.90, 'engagement counts within one only %.0f%% of the time', 100*within1);
    fprintf(['against %d hand-labelled member tracks: %.0f%% agree (sens %.2f, spec %.2f); ' ...
             'engagements per track exact %.0f%%, within one %.0f%% (his %.2f, this %.2f)\n'], ...
        numel(pred), 100*acc, sens, spec, 100*mean(nP(both)==nT(both)), 100*within1, ...
        mean(nT(truth)), mean(nP(pred)));
else
    fprintf('(the published VAPB folder is not on this machine — skipped the annotation check)\n');
end

fprintf('classify: %d/%d tracks engaged, %.2f engagements per engaged track; tau %.2f s under censoring (observed mean %.2f)\n', ...
    nnz(eng), nTr, mean([G.perTrack([G.perTrack.engaged]).nEngage]), Hc.groups.tau, Hc.groups.meanObs);
fprintf('histogram: conditions separated at p = %.2g, same-distribution control p = %.2g\n', H2.test.p, H3.test.p);
fprintf('warnings: heavy censoring and unequal observation windows both reported\n');
fprintf('\nENGAGE-CLASSIFY SMOKE PASSED.\n');
end
