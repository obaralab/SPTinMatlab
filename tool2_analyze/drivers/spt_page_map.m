function M = spt_page_map(sptPath, segPath, varargin)
%SPT_PAGE_MAP  Which page of an organelle stack goes with a tracked frame — read, not assumed.
%
%   M = spt_page_map(sptPath, segPath)
%   M = spt_page_map(sptPath, segPath, 'NSpt', n, 'NSeg', m)   when the counts are already known
%
% `page = frame + 1` is the rule this pipeline has always used, and it is right exactly when the
% tracked stack and the segmentation are on the same footing: one page each per moment of the
% acquisition. Two ordinary things break that, and both are silent:
%
%   * THE MOVIE IS INTERLEAVED. A stack off the microscope may hold several channels — the CysLig
%     `_ch24_spt.tif` files are 5,000 pages but 2,500 timepoints of two colours — while the mito
%     segmentation is one page per timepoint. Then tracked frame f belongs to timepoint
%     floor(f/nCh)+1, and `frame + 1` is wrong by a factor of nCh: it drifts through the movie and,
%     past the end of the shorter stack, clamps to the last page for everything after.
%   * THE ORGANELLE IS WINDOW-AVERAGED. A segmentation with far fewer pages than the movie averages
%     many frames per page, and a page is a WINDOW rather than an instant.
%
% WHAT THE PAGE COUNTS CANNOT SAY, AND WHAT THE LABELS ADD. The arithmetic of the mapping follows from
% the counts alone: 11,962 tracked pages over 5,981 segmented ones gives floor(f/2)+1 whether the
% movie is two channels against a per-timepoint mask or one channel averaged two frames to a page, and
% 5,000 over 5,000 gives f+1 either way. So the labels do not change WHICH PAGE is read. They change
% two other things, and both matter:
%
%   * WHAT THE MASK MEANS. One page per timepoint is the organelle AT that moment; w frames to a page
%     is where it was ON AVERAGE over w frames, which is a blur relative to any one of them and a
%     floor on what a distance to it can mean. Same index, different claim.
%   * WHETHER THE MOVIE SHOULD HAVE BEEN TRACKED AS IT WAS. A stack of 5,000 pages holding 2,500
%     timepoints of two channel numbers raises a question the counts are silent about, reported here as
%     .interleaved and entirely independent of the mask mapping being right. It is only a QUESTION: a
%     channel number is not a fluorophore, and two numbers in one camera's stack may be two exposures
%     of the same molecules a few ms apart, in which case tracking every page is correct.
%
% OUTPUT M
%   .relation  'perFrame'   the stacks agree page for page; page = frame + 1
%              'perTimepoint' the movie is interleaved and the segmentation is per timepoint
%              'window'     the segmentation averages several frames to a page
%              'single'     one segmented page for the whole movie
%              'unknown'    no labels and counts that do not divide — falls back to perFrame
%   .nSpt .nSeg .nCh .nTp   what was counted and what the labels said (NaN where they did not)
%   .interleaved            the labels name more than one channel NUMBER. Reported whatever the page
%                           relation turns out to be, because it is a separate question and the mask
%                           mapping can be perfectly right while it is open: IF those numbers are
%                           different fluorophores, a stack tracked as nSpt frames is linked across
%                           them at nTp/nSpt of the true interval; if they are repeated exposures of
%                           the same molecules, it is not. This reports; it does not decide.
%   .perPage                frames of the tracked stack per page of the segmentation
%   .pageOf                 function handle: 0-based tracked frame -> 1-based segmentation page
%   .agreesWithLegacy       true when .pageOf matches the frame+1 rule over the whole movie
%   .text                   one sentence for a panel or a log
%
% Nothing here corrects anything on its own. It reports, and a caller that wants the mapping applied
% passes M.pageOf to cs_channel_mask. Changing the default silently would move masks that are already
% in published figures.

p = inputParser;
p.addParameter('NSpt', []); p.addParameter('NSeg', []);
p.parse(varargin{:});

M = struct('relation','unknown', 'nSpt',NaN, 'nSeg',NaN, 'nCh',NaN, 'nTp',NaN, ...
           'interleaved',false, 'perPage',1, 'pageOf',@(f) round(f)+1, ...
           'agreesWithLegacy',true, 'text','');

M.nSpt = countPages(sptPath, p.Results.NSpt);
M.nSeg = countPages(segPath, p.Results.NSeg);

L = struct('ok',false);
if ~isempty(char(sptPath)) && isfile(char(sptPath)), L = spt_tiff_labels(char(sptPath)); end
if L.ok
    M.nCh = L.nCh;
    M.nTp = numel(unique(L.tp(isfinite(L.tp))));
    M.interleaved = numel(L.channels) > 1;
end

if ~isfinite(M.nSeg) || M.nSeg < 1
    M.text = 'no segmentation stack to map onto';
    if M.interleaved, M.text = [M.text '. ' interleavedNote(M, L)]; end
    return
end

if M.nSeg == 1
    M.relation = 'single'; M.perPage = Inf;
    M.pageOf = @(f) ones(size(f));
elseif isfinite(M.nTp) && M.nSeg == M.nTp && M.nSpt > M.nTp
    % The labels settle it: the movie is interleaved, the segmentation is one page per timepoint.
    M.relation = 'perTimepoint';
    M.perPage = M.nSpt / M.nTp;
    M.pageOf = pagerFor(M.perPage, M.nSeg);
elseif M.nSeg == M.nSpt
    M.relation = 'perFrame'; M.perPage = 1;
    M.pageOf = @(f) clampTo(round(f)+1, M.nSeg);
elseif isfinite(M.nSpt) && M.nSpt > M.nSeg
    w = M.nSpt / M.nSeg;
    M.relation = 'window'; M.perPage = w;
    M.pageOf = pagerFor(w, M.nSeg);
else
    M.relation = 'unknown'; M.perPage = 1;
    M.pageOf = @(f) clampTo(round(f)+1, M.nSeg);
end

% Does the mapping actually differ from the rule the pipeline has always used? Say so either way,
% because "this changes nothing here" is the useful answer most of the time.
if isfinite(M.nSpt) && M.nSpt >= 1
    f = unique(round(linspace(0, M.nSpt-1, min(M.nSpt, 512))));
    M.agreesWithLegacy = isequal(M.pageOf(f), clampTo(f+1, M.nSeg));
end
M.text = sentence(M);
if M.interleaved, M.text = [M.text '. ' interleavedNote(M, L)]; end
end

% =================================================================================================
function h = pagerFor(w, nSeg)
% Containment, not nearest-centre: page p covers frames [(p-1)*w, p*w), so the last frame of a page
% and the first of the next fall either side of the boundary rather than being rounded across it.
h = @(f) clampTo(floor(round(f) / w) + 1, nSeg);
end

function q = clampTo(q, n), q = min(max(q, 1), n); end

function n = countPages(path, given)
if ~isempty(given) && isscalar(given) && isfinite(given), n = double(given); return, end
n = NaN;
if ~(ischar(path) || isstring(path)) || isempty(char(path)) || ~isfile(char(path)), return, end
try, n = numel(imfinfo(char(path))); catch, end
end

function s = sentence(M)
switch M.relation
    case 'single'
        s = sprintf('one segmented page for all %g tracked frames — the same mask throughout', M.nSpt);
    case 'perTimepoint'
        s = sprintf(['the movie is %g channels interleaved (%g pages, %g timepoints) and the ' ...
            'segmentation is one page per timepoint, so tracked frame f belongs to page ' ...
            'floor(f/%g)+1 — NOT f+1, which drifts through the movie and clamps to the last page ' ...
            'after frame %g'], M.perPage, M.nSpt, M.nTp, M.perPage, M.nSeg);
    case 'perFrame'
        s = sprintf('%g tracked frames and %g segmented pages, one for one', M.nSpt, M.nSeg);
    case 'window'
        s = sprintf(['%g tracked frames over %g segmented pages: each page averages %.4g frames, ' ...
            'so a distance to it is a distance to where the organelle was on average over that ' ...
            'window'], M.nSpt, M.nSeg, M.perPage);
    otherwise
        s = sprintf(['%g tracked frames and %g segmented pages, with nothing in either file saying ' ...
            'how they correspond — falling back to page = frame + 1'], M.nSpt, M.nSeg);
end
if ~M.agreesWithLegacy
    s = [s '. This DISAGREES with the page = frame + 1 rule the pipeline applies by default'];
end
end

function s = interleavedNote(M, L)
% Stated, not diagnosed. A channel NUMBER is not a fluorophore: two numbers in one camera's stack may
% be two exposures of the same molecules a few ms apart, in which case tracking every page is right
% and de-interleaving would discard half the data. Only the person who ran the microscope knows.
s = sprintf(['SEPARATELY: the labels say this stack holds %d channel numbers (%s) over %g ' ...
    'timepoints in %g pages. If those are different fluorophores, tracking it as %g frames links ' ...
    'across them at %g times the true interval; if they are two exposures of the same molecules, ' ...
    'tracking every page is correct. Either way it is a different question from the mask mapping ' ...
    'and can be open while that is right.'], numel(L.channels), ...
    strjoin(arrayfun(@(c) sprintf('c:%d', c), L.channels, 'uni', 0), ' and '), M.nTp, M.nSpt, ...
    M.nSpt, 1/numel(L.channels));
end
