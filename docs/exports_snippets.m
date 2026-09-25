%% E0 load — point this at a project folder, then run blocks independently
% Companion to docs/EXPORTS_field_guide.html. Base MATLAB only; nothing here writes.
project = '/Users/safal-mac/Desktop/CysLig';
ana     = fullfile(project, 'analysis');

name   = strtrim(fileread(fullfile(ana,'active_trackstruct.txt')));   % which build is current
S      = load(fullfile(ana, name));  fn = fieldnames(S);
Tracks = S.(fn{1});                                    % 1 x nCells
CSW    = load(fullfile(ana,'CSW_final.mat')).CSW;      % 1 x nSites, the central record
calib  = load(fullfile(ana,'cs_calib.mat')).calib;
dt     = calib.dt_s;
fprintf('%s: %d cells, %d sites, %.4g um/px, %.4g s/frame\n', ...
    name, numel(Tracks), numel(CSW), calib.pixSizeUm, dt);

%% E1 overview — what this project holds
perCell = table((1:numel(Tracks))', string({Tracks.file})', ...
    arrayfun(@(t) numel(t.lengths), Tracks)', ...
    arrayfun(@(t) nnz(isfinite(t.matrix(:,:,2))), Tracks)', ...
    arrayfun(@(t) numel(t.allSpots.X), Tracks)', ...
    'VariableNames', {'cell','file','tracks','linkedLocs','allSpots'});
disp(head(perCell, 5))
fprintf('%d sites over %d conditions: %s\n', numel(CSW), ...
    numel(unique(string({CSW.condition}))), strjoin(unique(string({CSW.condition})), ', '));

%% E2 the matrix idiom — one cell, one track
T     = Tracks(1);
frame = T.matrix(:,:,1);              % 0-BASED frame; NaN below a track's end
x     = T.matrix(:,:,2);              % um
y     = T.matrix(:,:,3);              % um

j  = 5;                               % one track = one COLUMN (1-based)
ok = isfinite(x(:,j));                % exactly T.lengths(j) of them
f0 = frame(find(ok,1), j);  f1 = frame(find(ok,1,'last'), j);
fprintf('track %d: %d localizations over frames %d..%d (%d gap frames), %.2f s\n', ...
    j, T.lengths(j), f0, f1, (f1-f0+1) - T.lengths(j), (f1-f0)*dt);

% a set of linear indices addresses ONE PAGE, and so reaches all three
ids = find(isfinite(x));
got = [frame(ids), x(ids), y(ids)];   % same rows, three columns
fprintf('%d linked localizations in this cell\n', size(got,1));

%% E3 tool 1 — the per-cell CSVs
base = erase(char(Tracks(1).file), '_Tracks');
Sp = readtable(fullfile(project,'tracks',[base '_spots.csv']));
fprintf('%d detections, %d linked (%.1f%%)\n', height(Sp), nnz(~isnan(Sp.TRACK_ID)), ...
    100*mean(~isnan(Sp.TRACK_ID)));

id = Sp.TRACK_ID(find(~isnan(Sp.TRACK_ID), 1));        % a TRACK_ID, 0-BASED
r  = sortrows(Sp(Sp.TRACK_ID == id, :), 'FRAME');
fprintf('TRACK_ID %d: %d spots, frames %d..%d\n', id, height(r), r.FRAME(1), r.FRAME(end));
% MITO_DIST_UM is SIGNED: negative means inside the segmented organelle
fprintf('  %.0f%% of its localizations are inside mito\n', 100*mean(r.MITO_DIST_UM < 0));

M = readtable(fullfile(project,'tracks',[base '_track_metrics.csv']));
fprintf('%d tracks scored, %d kept by the filter\n', height(M), nnz(M.KEEP == 1));

%% E4 tool 1 — the settings file, as a struct
txt = fileread(fullfile(project,'tracks',[base '_settings.txt']));
kv  = regexp(txt, '^\s*([\w.]+)\s*=\s*(.+?)\s*$', 'tokens', 'lineanchors');
P   = struct();
for i = 1:numel(kv), P.(matlab.lang.makeValidName(kv{i}{1})) = kv{i}{2}; end
fprintf('pixel %s um (%s), frame %s s (%s), link %s um, gap %s frames\n', ...
    P.calibration_pixel_um, P.calibration_pixel_um_src, ...
    P.calibration_frame_s,  P.calibration_frame_s_src, ...
    P.tracking_link_um, P.tracking_max_gap_frames);

%% E5 the manifest — where conditions are assigned
manifest = load(fullfile(project,'experiment_details.mat')).manifest;
C = manifest.cells;
fprintf('%d cells in the manifest, %d excluded\n', numel(C), nnz([C.exclude]));
disp(groupsummary(table(string({C.condition})', [C.nTracks]', ...
    'VariableNames', {'condition','nTracks'}), 'condition', 'sum', 'nTracks'))

%% E6 footprints — and which outlines are set by the smoothing rather than the data
L = load(fullfile(ana,'CS_footprints.mat'));
F = L.CSfoot(~[L.CSfoot.deleted]);
floorR = 1.1774 * L.outlineSigmaNm / 1000;             % um: the smallest possible auto radius

rr = sqrt([F.areaUm2] / pi);
fprintf('sigma %g nm -> floor %.0f nm (%.4f um^2)\n', L.outlineSigmaNm, floorR*1000, pi*floorR^2);
fprintf('%d of %d outlines sit within 25%% of that floor; %d at or below it\n', ...
    nnz(rr < floorR*1.25), numel(F), nnz(rr <= floorR));
atFloor = find(rr < floorR*1.25 & contains(string({F.mode}), 'halfmax'));
for k = atFloor(1:min(5,numel(atFloor)))
    fprintf('   %s csID %-3d r = %3.0f nm  (%s)\n', F(k).file, F(k).csID, rr(k)*1000, F(k).mode);
end

%% E7 one site from CSW — outline, members, neighbours
s = CSW([CSW.siteUID] == 1);
Tc = Tracks(s.cellIndex);
X = Tc.matrix(:,:,2);  Y = Tc.matrix(:,:,3);
outline = s.refboundary + s.refCenter;                 % CSW keeps refboundary in um

fprintf('site %d (%s csID %d, %s): %.4f um^2, %d tracks, %d locs inside, enrichment %.1fx\n', ...
    s.siteUID, s.file, s.csID, s.condition, s.areaUm2, s.nTracks, s.nLocInside, s.enrichment);

figure; hold on
plot(X(s.neighborIDs), Y(s.neighborIDs), '.', 'Color', [.3 .7 .9]);   % in the square, outside
plot(X(s.LocIDs),      Y(s.LocIDs),      '.', 'Color', [.85 .2 .2]);  % inside the outline
plot(outline(:,1), outline(:,2), 'k-', 'LineWidth', 1.5);
plot(s.boundaries.x([1 2 2 1 1]), s.boundaries.y([1 1 2 2 1]), 'k--');
axis equal; set(gca,'YDir','reverse'); xlabel('x (\mum)'); ylabel('y (\mum)');
title(sprintf('site %d: %.3f \\mum^2, enrichment %.1fx', s.siteUID, s.areaUm2, s.enrichment));

%% E8 sites by condition
keep = ~[CSW.excluded];
W = CSW(keep);
R = table(string({W.condition})', [W.MitoFlag]', [W.areaUm2]', [W.enrichment]', ...
          [W.nLocInside]', [W.nTracks]', ...
          'VariableNames', {'condition','mito','areaUm2','enrichment','nLoc','nTracks'});
disp(groupsummary(R, {'condition','mito'}, 'median', {'areaUm2','enrichment'}))

%% E9 dwell times by condition, with censoring handled
DD = load(fullfile(ana,'cs_window_dwell.mat')).DD;

% CSW carries the condition, the dwell records carry siteUID: join on it.
cond = strings(max([CSW.siteUID]), 1);
cond([CSW.siteUID]) = string({CSW.condition});

% a visit is only fully observed when its track both ENTERS and EXITS in the window
lab  = DD.perTrack;
labK = string({lab.file})' + "|" + [lab.siteUID]' + "|" + [lab.trackCol]';
labV = string({lab.label})';

ev   = DD.events;
evK  = string({ev.file})' + "|" + [ev.siteUID]' + "|" + [ev.trackCol]';
[tf, loc] = ismember(evK, labK);
complete = false(numel(ev),1);
complete(tf) = labV(loc(tf)) == "ENTERS+EXITS";

% cond is a column and [ev.siteUID] is a row; indexing a vector with a vector keeps the
% SOURCE's orientation, so this is already Nx1 and must not be transposed again.
E = table(cond([ev.siteUID]), [ev.dwell]', complete, ...
          'VariableNames', {'condition','dwell_s','complete'});
fprintf('%d visits, %d fully observed (%.0f%%)\n', height(E), nnz(E.complete), ...
    100*mean(E.complete));

Cc = E(E.complete & E.condition ~= "", :);
if ~isempty(Cc)
    disp(groupsummary(Cc, 'condition', {'median','mean'}, 'dwell_s'))
    figure; hold on
    u = unique(Cc.condition);
    for k = 1:numel(u)
        histogram(Cc.dwell_s(Cc.condition == u(k)), 0:0.25:8, ...
            'DisplayStyle','stairs', 'Normalization','pdf');
    end
    legend(cellstr(u), 'Interpreter','none');
    xlabel('dwell (s)'); ylabel('pdf'); title('complete visits by condition');
else
    fprintf(['no conditions on the dwell records: CSW carries them but this run predates the\n' ...
             'stamping. Re-run the mapper/classifier, or join as above.\n']);
end

%% E10 engagement — per site and per track
G = load(fullfile(ana,'cs_engage.mat')).G;
fprintf('denominator = %s, minEngage = %.2f s\n', G.params.denominator, G.params.minEngage_s);
PS = G.perSite;
fprintf('%d sites: median %.0f%% of member tracks engaged, median dwell %.2f s\n', ...
    numel(PS), 100*median([PS.fracEngaged]), median([PS.medianDwell_s], 'omitnan'));

PT = G.perTrack;
fprintf('%d track-at-site records, %d engaged, %d of those censored (%.0f%%)\n', ...
    numel(PT), nnz([PT.engaged]), nnz([PT.engaged] & [PT.censored]), ...
    100*nnz([PT.engaged] & [PT.censored]) / max(nnz([PT.engaged]),1));

%% E11 from a CSV row back to the trajectory
Et = readtable(fullfile(ana,'cs_engage_tracks.csv'), 'VariableNamingRule','preserve');
r  = Et(find(Et.engaged == 1, 1), :);
c  = find(strcmp({Tracks.file}, r.file{1}));
Tj = Tracks(c);
j  = r.trackCol;                        % a COLUMN of that cell's matrix, 1-based
fprintf('%s column %d: %d localizations, %d engagement(s), longest %.2f s\n', ...
    r.file{1}, j, nnz(isfinite(Tj.matrix(:,j,2))), r.nEngage, r.longest_s);
fprintf('  its TRACK_ID in the tool 1 CSVs is %d\n', Tj.trackIDs(j));

%% E12 the advisor export — load a condition folder
folder = fullfile(ana,'exports','test_20260924-131429','advisor_format','Baseline');
if isfolder(folder)
    A  = load(fullfile(folder,'CS_final_v3.mat')).CS;
    d  = dir(fullfile(folder,'*_Tracks_final*.mat'));
    AT = load(fullfile(d(1).folder,d(1).name)).Tracks;
    I  = readtable(fullfile(folder,'imaging_settings.csv'));
    dtA = median(I.frame_interval_s, 'omitnan');
    fprintf('%d cells, %d sites, %.4g s/frame\n', numel(AT), numel(A), dtA);

    a = A(1);
    % THE ONE UNITS EXCEPTION: refboundary is nm, relative to refCenter (um)
    outline_um = a.refboundary/1000 + a.refCenter;
    fprintf('CS %d: %.4f um^2, %d tracks, %d inside, %d neighbours\n', a.CS_index, ...
        polyarea(outline_um(:,1), outline_um(:,2)), numel(a.tracks), ...
        numel(a.refLocIDs), numel(a.neighborIDs));

    % refLocIDs index the CELL's matrix; CSLocIDs index this site's CSmatrix
    Pcs = a.CSmatrix(:,:,1);
    [row, jj] = ind2sub(size(Pcs), a.CSLocIDs);
    back = sub2ind(size(AT(a.cellIndex).matrix(:,:,1)), row, a.tracks(jj)');
    assert(isequal(sort(back), sort(a.refLocIDs)), 'the two index systems must agree');
    fprintf('  inside per member track: %s\n', ...
        mat2str(accumarray(jj(:), 1, [numel(a.tracks) 1])'));
else
    fprintf('no advisor export at %s — make one from the Contact sites tab\n', folder);
end

%% E13 site sizes against the published VAPB set
ref = '/Users/safal-mac/Desktop/VAPB_nature/CS_final_v3.mat';
if isfolder(folder) && isfile(ref)
    rad = @(Q) arrayfun(@(e) sqrt(polyarea(e.refboundary(:,1)/1000, ...
                                           e.refboundary(:,2)/1000)/pi)*1000, Q);
    mine = rad(A);
    theirs = rad(load(ref).CS);
    fprintf('this export  n=%3d  median %3.0f nm  [%3.0f .. %3.0f]\n', ...
        numel(mine), median(mine), min(mine), max(mine));
    fprintf('VAPB         n=%3d  median %3.0f nm  [%3.0f .. %3.0f]\n', ...
        numel(theirs), median(theirs), min(theirs), max(theirs));
    figure; hold on
    histogram(mine,   0:25:600, 'DisplayStyle','stairs', 'Normalization','probability');
    histogram(theirs, 0:25:600, 'DisplayStyle','stairs', 'Normalization','probability');
    xline(1.1774*100, 'k--');           % no automatic outline can be smaller than this
    legend({'this export','VAPB','\sigma floor'});
    xlabel('equivalent radius (nm)'); ylabel('fraction of sites');
end

%% E14 inventory — every export this project holds
for f = dir(fullfile(ana,'*.csv'))'
    try
        Tt = readtable(fullfile(ana,f.name), 'VariableNamingRule','preserve');
        fprintf('%-34s %6d rows x %2d cols\n', f.name, height(Tt), width(Tt));
    catch
        fprintf('%-34s (unreadable)\n', f.name);
    end
end
for f = dir(fullfile(ana,'*.mat'))'
    w = whos('-file', fullfile(ana,f.name));
    fprintf('%-34s %s\n', f.name, strjoin(arrayfun(@(v) ...
        sprintf('%s %s', v.name, mat2str(v.size)), w, 'uni', 0), ', '));
end
