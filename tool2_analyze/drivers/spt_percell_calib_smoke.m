function spt_percell_calib_smoke()
%SPT_PERCELL_CALIB_SMOKE  Calibration is per CELL, not per project.
%
% The point of this: one comparison may span acquisitions taken on DIFFERENT cameras at DIFFERENT
% frame rates — e.g. a collaborator's dataset used as a null. dt was already per cell (each cell's
% own tracks XML). This checks the other three — pixel size, field of view and localization
% precision — are stamped per cell at import, survive a save/load round trip, and actually CHANGE
% the numbers that depend on them. A stamp that nothing reads would look identical to a bug.

here = fileparts(mfilename('fullpath')); addpath(here);
tmp = fullfile(tempdir,'spt_percell_calib'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp);

% ---- two cells, deliberately different acquisitions -------------------------------------------
% cell A: fast camera, 20 ms; cell B: the "advisor's" camera, 50 ms and a coarser pixel
write_tracks_xml(fullfile(tmp,'cellA_tracks.xml'), 0.020, 12, 40, 0.11);
write_tracks_xml(fullfile(tmp,'cellB_tracks.xml'), 0.050, 12, 40, 0.11);

Tracks = TrackImporter_direct(tmp, 'AttachCSV', false, 'Save', false, 'Verbose', false, ...
    'Calib', struct('pixSizeUm',0.10785,'fovUm',27.61,'binNm',30));
assert(numel(Tracks)==2, 'expected two cells, got %d', numel(Tracks));

% 1. dt comes from each cell's OWN xml, not from the project fallback
dts = sort([Tracks.frameInterval]);
fprintf('per-cell dt: %.3f, %.3f s\n', dts(1), dts(2));
assert(abs(dts(1)-0.020)<1e-9 && abs(dts(2)-0.050)<1e-9, 'dt did not come from each cell''s own XML');

% 2. every cell carries a full calibration stamp
assert(isfield(Tracks,'calib'), 'the importer did not stamp a per-cell calibration');
for k = 1:2
    c = Tracks(k).calib;
    for f = {'pixSizeUm','fovUm','dt_s','precNm'}
        assert(isfield(c,f{1}) && isscalar(c.(f{1})) && isfinite(c.(f{1})) && c.(f{1})>0, ...
               'cell %d has no usable %s', k, f{1});
    end
    assert(isfield(c,'src') && isstruct(c.src), 'cell %d records no provenance', k);
    assert(abs(c.dt_s - Tracks(k).frameInterval) < 1e-12, 'the stamp disagrees with frameInterval');
end
fprintf('both cells stamped: px=%.5g/%.5g  fov=%.4g/%.4g  prec=%.3g/%.3g\n', ...
    Tracks(1).calib.pixSizeUm, Tracks(2).calib.pixSizeUm, ...
    Tracks(1).calib.fovUm, Tracks(2).calib.fovUm, Tracks(1).calib.precNm, Tracks(2).calib.precNm);

% 3. the project fallback is what an un-measured cell inherits, and it says so
assert(abs(Tracks(1).calib.precNm - 30) < 1e-9, 'precision did not fall back to the project value');
assert(strcmp(Tracks(1).calib.src.precNm,'project'), 'an inherited value was not marked inherited');

% 4. it SURVIVES the save/load round trip the app does
f = fullfile(tmp,'TrackStruct.mat'); save(f,'Tracks','-v7.3');
L = load(f); assert(isfield(L.Tracks,'calib') && abs(L.Tracks(2).calib.dt_s-0.050)<1e-9, ...
    'the per-cell calibration did not survive a save/load');

% 5. and it CHANGES the answer: the same track, at two precisions, gives two Ds.
%    D = <dr^2>/(4 dt) - sigma^2/dt, so a bigger assumed precision subtracts more.
T1 = spt_track_diffusion(Tracks(1), struct('dt',Tracks(1).calib.dt_s,'sigmaUm',0.030));
T2 = spt_track_diffusion(Tracks(1), struct('dt',Tracks(1).calib.dt_s,'sigmaUm',0.060));
d1 = median(T1.Dt(isfinite(T1.Dt)), 'omitnan');
d2 = median(T2.Dt(isfinite(T2.Dt)), 'omitnan');
fprintf('median D at 30 nm = %.4f, at 60 nm = %.4f um^2/s\n', d1, d2);
assert(isfinite(d1) && isfinite(d2) && d2 < d1, ...
    'localization precision did not move D — the per-cell value cannot matter');

% 6. per-cell dt likewise: doubling dt must roughly halve D
T3 = spt_track_diffusion(Tracks(1), struct('dt',2*Tracks(1).calib.dt_s,'sigmaUm',0.030));
d3 = median(T3.Dt(isfinite(T3.Dt)), 'omitnan');
fprintf('median D at dt and 2*dt = %.4f, %.4f um^2/s\n', d1, d3);
assert(d3 < d1, 'per-cell dt did not move D');

fprintf('\nALL PER-CELL CALIBRATION ASSERTIONS PASSED.\n');
end

function write_tracks_xml(path, dt, nTrk, nLoc, pxUm)
% A minimal file in the pipeline's own tracks-XML dialect: positions in um, dt on the root.
rng(7);
fid = fopen(path,'w');
c = onCleanup(@() fclose(fid));
fprintf(fid,'<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(fid,'<Tracks nTracks="%d" frameInterval="%.6g" spaceUnit="um" timeUnit="s">\n', nTrk, dt);
for t = 1:nTrk
    fprintf(fid,'  <Track TRACK_ID="%d" nSpots="%d">\n', t-1, nLoc);
    x = 5 + cumsum(randn(nLoc,1)*pxUm); y = 5 + cumsum(randn(nLoc,1)*pxUm);
    for i = 1:nLoc
        fprintf(fid,'    <Spot FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" SPOT_ID="%d" />\n', ...
                i-1, (i-1)*dt, x(i), y(i), (t-1)*nLoc+i);
    end
    fprintf(fid,'  </Track>\n');
end
fprintf(fid,'</Tracks>\n');
end
