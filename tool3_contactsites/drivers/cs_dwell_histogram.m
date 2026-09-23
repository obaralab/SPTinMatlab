function H = cs_dwell_histogram(src, opts)
%CS_DWELL_HISTOGRAM  Pool engagement dwell times and compare them between conditions.
%
%   H = cs_dwell_histogram(G)                          % G from cs_engage_classify
%   H = cs_dwell_histogram(G, struct('group','condition','ax',ax))
%   H = cs_dwell_histogram(dwellStruct, opts)          % or G.dwell / DD.events directly
%
% One row per group (a condition, a cell, mito vs not, or everything pooled), with the histogram to
% draw and the numbers to quote - and a test of whether two groups differ.
%
% CENSORING IS THE THING TO GET RIGHT. A visit that is still going when the track ends did not last
% that long, it lasted AT LEAST that long, and those are exactly the long visits a histogram is being
% asked about. So the mean of the observed durations is biased LOW, and the more photostable the dye
% the less it is. .tau is therefore the exponential maximum-likelihood estimate that uses the
% censored visits for their length but not as completions:
%
%       tau = (total time spent engaged) / (number of visits that were seen to END)
%
% which needs no toolbox and reduces to the plain mean when nothing is censored. k_off = 1/tau.
% .medianObs is the median of what was seen, for reporting alongside - not a substitute.
%
% opts
%   .group      'condition' (default) | 'file' | 'cell' | 'mito' | 'site' | 'none'
%   .edges      histogram bin edges (s); default 0 to the 98th percentile in .nBins bins
%   .nBins      (24)
%   .normalize  'probability' (default: bars sum to 1, so groups of different n compare) |
%               'count' | 'pdf'
%   .minN       (5) groups with fewer visits are kept in the table but flagged .thin
%   .ax         draw into this axes (histogram per group). [] = no plot.
%   .survival   (false) also draw 1-CDF on a log y axis, where an exponential is a straight line
%   .useCensored (true) include censored visits in tau (as time, not as completions) and in the
%               histogram; false drops them entirely, which biases the histogram short but is what
%               a hand-picked set of complete events looks like.
%
% OUTPUT H
%   .groups   struct array: .name .n .nCensored .tau .koff .medianObs .meanObs .p25 .p75 .counts
%             .thin .totalTime_s
%   .edges    the bin edges every group's .counts is on (shared, so they are comparable)
%   .test     pairwise two-sample Kolmogorov-Smirnov between groups: .a .b .D .p .n1 .n2
%             (on the uncensored visits, since the test compares distributions of completed times).
%             IT COUNTS VISITS, and visits from one cell are not independent of each other - see
%             .cellTest, which is the one to quote.
%   .byCell   each group's cells with their own n, tau and median - the unit of replication
%             Both families carry .pAdj, Holm-adjusted over the comparisons made: five conditions are
%             ten comparisons, and one p under 0.05 in ten is what chance looks like. Quote .pAdj.
%   .cellTest the same pairwise comparison over the per-CELL medians (Mann-Whitney; .exact says
%             whether the p-value was enumerated rather than approximated). Few points, but the
%             right ones: a condition with 2 cells cannot support a claim however many visits it has.
%   .note     what was pooled, in words, for a figure caption
%   .warnings the two ways this comparison misleads, when they apply: heavy censoring (tau then rests
%             on the exponential assumption, and the observed median is nearer the observation window
%             than a residence time), and groups watched for unequal lengths of time (a longer
%             observation window alone lengthens dwells). Each group also carries .censoredFrac and
%             .medianWindow_s so this can be checked directly.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
grp   = lower(getf(opts,'group','condition'));
nB    = getf(opts,'nBins',24);
nrm   = lower(getf(opts,'normalize','probability'));
minN  = getf(opts,'minN',5);
ax    = getf(opts,'ax',[]);
doSurv= getf(opts,'survival',false);
useC  = getf(opts,'useCensored',true);

D = src;
if isstruct(src) && isfield(src,'dwell'), D = src.dwell; end
if isstruct(src) && ~isfield(src,'dwell') && isfield(src,'events') && ~isfield(src,'dwell_s')
    D = src.events;                                        % a cs_window_dwell DD
end
H = struct('groups',emptyGroup(),'edges',[],'test',emptyTest(),'note','');
if isempty(D), H.note = 'no engagements to pool'; return; end

dv = colOf(D, {'dwell_s','dwell'});
cens = colOf(D, {'censored'}); if isempty(cens), cens = false(size(dv)); end
cens = logical(cens);
ok = isfinite(dv) & dv > 0;
dv = dv(ok); cens = cens(ok); D = D(ok);
if ~useC, keepv = ~cens; dv = dv(keepv); cens = cens(keepv); D = D(keepv); end
if isempty(dv), H.note = 'no engagements left after filtering'; return; end

% ---- the grouping key ----
switch grp
    case 'condition', key = strOf(D,'condition'); lbl = 'condition';
    case {'file','cell'}, key = strOf(D,'file'); lbl = 'cell';
    case 'mito', key = arrayfun(@(s) tern(logical(fieldOr(s,'mito',false)),"mito","non-mito"), D(:)); lbl = 'neighbour';
    case 'site', key = arrayfun(@(s) string(sprintf('site %d', fieldOr(s,'siteUID',0))), D(:)); lbl = 'site';
    otherwise, key = repmat("all", numel(dv), 1); lbl = 'all sites';
end
key = string(key(:)); key(key == "" | ismissing(key)) = "unlabelled";
names = unique(key, 'stable');
if strcmp(grp,'condition') && isscalar(names) && names(1) == "unlabelled"
    names(1) = "all"; key(:) = "all";                      % a single folder has no conditions yet
    lbl = 'all sites (no conditions assigned — set them in the experiment manifest)';
end

edges = getf(opts,'edges',[]);
if isempty(edges)
    hi = prctile0(dv, 98); if ~(hi > 0), hi = max(dv); end
    edges = linspace(0, hi, max(nB,4) + 1);
end
edges = edges(:)';

obsv = colOf(D, {'trackObs_s'});                            % the observable window per visit, if known
for q = 1:numel(names)
    m = key == names(q);
    d = dv(m); c = cens(m);
    ow = NaN; if ~isempty(obsv), ow = median(obsv(m), 'omitnan'); end
    nEnd = nnz(~c);                                        % visits seen to end
    tau = sum(d) / max(nEnd, 1);                           % censoring-aware exponential MLE
    if nEnd == 0, tau = NaN; end
    cnt = histcounts(d, edges);
    switch nrm
        case 'count'
        case 'pdf', cnt = cnt ./ (sum(cnt) * diff(edges));
        otherwise,  cnt = cnt / max(sum(cnt),1);
    end
    H.groups(end+1) = struct('name',char(names(q)),'n',numel(d),'nCensored',nnz(c), ...
        'censoredFrac',mean(c),'tau',tau,'koff',1/tau,'medianObs',median(d),'meanObs',mean(d), ...
        'p25',prctile0(d,25),'p75',prctile0(d,75),'counts',cnt,'thin',numel(d) < minN, ...
        'totalTime_s',sum(d),'medianWindow_s',ow,'censorHeavy',mean(c) > 0.5,'nCells',NaN); %#ok<AGROW>
end
H.edges = edges;

% ---- pairwise comparison ----
for a = 1:numel(names)
    for b = a+1:numel(names)
        x = dv(key == names(a) & ~cens); y = dv(key == names(b) & ~cens);
        if numel(x) < 3 || numel(y) < 3, continue; end
        [Dst, p] = ks2(x, y);
        H.test(end+1) = struct('a',char(names(a)),'b',char(names(b)),'D',Dst,'p',p,'pAdj',NaN, ...
            'n1',numel(x),'n2',numel(y),'exact',false); %#ok<AGROW>   % KS p is asymptotic
    end
end

% ---- the CELL is the unit of replication, not the visit ----------------------------------------
% Engagements cluster within a cell: the same dish, the same transfection, the same day. A test over
% pooled visits treats 600 visits from 8 cells as 600 independent observations, which is how a
% condition difference passes a test it should not. So each group also gets its cells' own medians,
% and the comparison is repeated over THOSE - few points, exact when it can be, and honest about it.
cellKey = strOf(D,'file');
H.byCell = emptyCell();
for q = 1:numel(names)
    m = key == names(q);
    cs = unique(cellKey(m), 'stable');
    for c = 1:numel(cs)
        mc = m & cellKey == cs(c);
        dc = dv(mc); cc = cens(mc);
        nEndc = nnz(~cc);
        H.byCell(end+1) = struct('group',char(names(q)),'file',char(cs(c)),'n',nnz(mc), ...
            'tau',sum(dc)/max(nEndc,1),'medianObs',median(dc),'nCensored',nnz(cc)); %#ok<AGROW>
    end
    H.groups(q).nCells = numel(cs);
end
H.cellTest = emptyTest();
for a2 = 1:numel(names)
    for b2 = a2+1:numel(names)
        x = [H.byCell(strcmp({H.byCell.group}, char(names(a2)))).medianObs];
        y = [H.byCell(strcmp({H.byCell.group}, char(names(b2)))).medianObs];
        if numel(x) < 2 || numel(y) < 2, continue; end
        [pv, exact] = ranksum2(x, y);
        H.cellTest(end+1) = struct('a',char(names(a2)),'b',char(names(b2)),'D',NaN,'p',pv,'pAdj',NaN, ...
            'n1',numel(x),'n2',numel(y),'exact',exact); %#ok<AGROW>
    end
end

% FIVE CONDITIONS MAKE TEN COMPARISONS, and one of ten p-values under 0.05 is what chance looks
% like. Holm-adjusted within each family (visit-level and cell-level separately), which is uniformly
% more powerful than Bonferroni and just as safe: .p is the raw value, .pAdj the one to quote.
H.test = holm(H.test);
H.cellTest = holm(H.cellTest);

H.note = sprintf('%d engagements over %d %s(s), %.0f%% censored; grouped by %s; tau uses the censored visits for their time but not as completions', ...
    numel(dv), numel(names), lbl, 100*mean(cens), lbl);
% TWO WAYS THIS COMPARISON GOES WRONG, both worth saying out loud rather than leaving in the data.
H.warnings = {};
heavy = [H.groups.censorHeavy];
if any(heavy)
    H.warnings{end+1} = sprintf(['%s: over half the visits are still running when their track ends, ' ...
        'so tau rests on the exponential assumption rather than on observed exits - and the median ' ...
        'of what was seen is closer to the observation window than to a residence time'], ...
        strjoin({H.groups(heavy).name}, ', '));
end
thinCells = [H.groups.nCells] < 3;
if any(thinCells)
    H.warnings{end+1} = sprintf(['%s: %s cell(s) behind it. Engagements cluster within a cell, so the ' ...
        'event-level test (H.test) counts them as independent when they are not — use the cell-level ' ...
        'one (H.cellTest) and read a difference here as provisional'], ...
        strjoin({H.groups(thinCells).name}, ', '), strjoin(compose('%d', [H.groups(thinCells).nCells]), '/'));
end
w = [H.groups.medianWindow_s];
if numel(w) > 1 && all(isfinite(w)) && max(w)/min(w) > 1.25
    [~, iw] = max(w); [~, jw] = min(w);
    H.warnings{end+1} = sprintf(['the groups were not watched for the same length of time (%s %.2f s ' ...
        'vs %s %.2f s per track): a longer observation window alone produces longer dwells, so match ' ...
        'the track lengths before reading a difference as biology'], ...
        H.groups(iw).name, w(iw), H.groups(jw).name, w(jw));
end

% ---- the plot ----
if ~isempty(ax) && isgraphics(ax)
    cla(ax); hold(ax,'on');
    co = get(ax,'ColorOrder'); ctr = edges(1:end-1) + diff(edges)/2;
    if doSurv
        for q = 1:numel(H.groups)
            d = sort(dv(key == names(q)));
            stairs(ax, d, 1 - (0:numel(d)-1)'/numel(d), '-', 'LineWidth', 1.6, ...
                'Color', co(mod(q-1,size(co,1))+1,:), 'DisplayName', labelOf(H.groups(q)));
        end
        set(ax,'YScale','log'); ylabel(ax,'fraction still engaged');
    else
        w = 0.8*mean(diff(edges))/max(numel(H.groups),1);
        for q = 1:numel(H.groups)
            off = (q - (numel(H.groups)+1)/2) * w;
            bar(ax, ctr + off, H.groups(q).counts, w/mean(diff(edges)), 'FaceColor', ...
                co(mod(q-1,size(co,1))+1,:), 'EdgeColor','none', 'FaceAlpha',0.85, ...
                'DisplayName', labelOf(H.groups(q)));
        end
        ylabel(ax, tern(strcmp(nrm,'count'),'engagements',tern(strcmp(nrm,'pdf'),'density','fraction of engagements')));
    end
    xlabel(ax,'Dwell time (s)');
    if numel(H.groups) > 1, legend(ax,'show','Location','northeast','Box','off'); end
    hold(ax,'off');
end
end

% =================================================================================================
function s = labelOf(g)
s = sprintf('%s (n=%d, \\tau=%.2f s)', g.name, g.n, g.tau);
end

function [D, p] = ks2(x, y)
% Two-sample Kolmogorov-Smirnov, written out so this needs no toolbox.
x = sort(x(:)); y = sort(y(:)); n1 = numel(x); n2 = numel(y);
all_ = sort([x; y]);
F1 = arrayfun(@(t) nnz(x <= t), all_) / n1;
F2 = arrayfun(@(t) nnz(y <= t), all_) / n2;
D = max(abs(F1 - F2));
ne = n1*n2/(n1+n2); lam = (sqrt(ne) + 0.12 + 0.11/sqrt(ne)) * D;
p = 0; for k = 1:100, p = p + 2*(-1)^(k-1) * exp(-2*k^2*lam^2); end
p = min(max(p, 0), 1);
end

function v = colOf(S, names)
v = [];
for q = 1:numel(names)
    if isfield(S, names{q}), v = [S.(names{q})]'; return; end
end
end

function s = strOf(S, f)
if ~isfield(S, f), s = repmat("", numel(S), 1); return; end
s = arrayfun(@(x) string(char(fieldOr(x, f, ''))), S(:));
end

function G = emptyGroup()
G = struct('name',{},'n',{},'nCensored',{},'censoredFrac',{},'tau',{},'koff',{},'medianObs',{}, ...
    'meanObs',{},'p25',{},'p75',{},'counts',{},'thin',{},'totalTime_s',{},'medianWindow_s',{}, ...
    'censorHeavy',{},'nCells',{});
end
function T = emptyTest()
T = struct('a',{},'b',{},'D',{},'p',{},'pAdj',{},'n1',{},'n2',{},'exact',{});
end

function T = holm(T)
% Holm step-down over the comparisons in one family: sort ascending, scale each by the number still
% to be tested, and enforce monotonicity so a later p can never be adjusted below an earlier one.
if isempty(T), return; end
p = [T.p]; m = numel(p);
[ps, i] = sort(p);
adj = min(1, ps .* (m:-1:1));
adj = cummax(adj);
out = zeros(1, m); out(i) = adj;
for k = 1:m, T(k).pAdj = out(k); end
end
function C = emptyCell()
C = struct('group',{},'file',{},'n',{},'tau',{},'medianObs',{},'nCensored',{});
end

function [p, exact] = ranksum2(x, y)
% Mann-Whitney U, two-sided, toolbox-free. EXACT by enumerating the splits when the groups are small
% enough - which is exactly the case here, where a condition may have 2 cells and a normal
% approximation would be a fiction.
x = x(:); y = y(:); n1 = numel(x); n2 = numel(y); N = n1 + n2;
r = tiedrank_([x; y]);
U = sum(r(1:n1)) - n1*(n1+1)/2;
exact = false;
if nchoosek(N, min(n1,N-n1)) <= 50000
    exact = true;
    C = nchoosek(1:N, n1);
    Us = zeros(size(C,1),1);
    for q = 1:size(C,1), Us(q) = sum(r(C(q,:))) - n1*(n1+1)/2; end
    mu = n1*n2/2;
    p = mean(abs(Us - mu) >= abs(U - mu) - 1e-9);
else
    [~,~,ic] = unique([x; y]); cnt = accumarray(ic,1);
    sd = sqrt(n1*n2/12 * ((N+1) - sum(cnt.^3 - cnt)/(N*(N-1))));
    z = (U - n1*n2/2) / max(sd, eps);
    p = erfc(abs(z)/sqrt(2));
end
p = min(max(p,0),1);
end

function r = tiedrank_(v)
v = v(:); n = numel(v);
[sv, i] = sort(v); r0 = (1:n)';
r = zeros(n,1);
q = 1;
while q <= n                                  % average the ranks of ties
    j = q; while j < n && sv(j+1) == sv(q), j = j + 1; end
    r0(q:j) = mean(q:j); q = j + 1;
end
r(i) = r0;
end
function p = prctile0(x, q)
x = sort(x(isfinite(x))); if isempty(x), p = NaN; return; end
p = interp1((0.5:numel(x)-0.5)/numel(x), x, q/100, 'linear', 'extrap');
end
function v = tern(c,a,b), if c, v=a; else, v=b; end, end
function v = fieldOr(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
